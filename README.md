# xray-reality-multiregion-vpn

A multi-region VLESS+REALITY proxy deployment: three VPS nodes across two countries, each fronted by a zero-downtime blue-green TCP passthrough, plus a cross-region relay chain and a small Python control-plane CLI. This repo documents the architecture, the engineering decisions behind it, and the tooling — with all server addresses, keys, and client identifiers replaced by placeholders. It is a sanitized companion to a real deployment I operate, published as evidence of the systems/network engineering work referenced in my grad-school application materials.

**Author:** Y.J. Xu · [github.com/ethan0502](https://github.com/ethan0502)

---

## What this is

A self-hosted [VLESS+REALITY](https://github.com/XTLS/REALITY) proxy service, deployed independently across three VPS nodes (two countries, three hosting providers), each with:

- A **TCP passthrough front door** (nginx `stream` module or HAProxy, depending on what the host's package repos actually support) that never terminates TLS — REALITY's whole security model depends on the origin server's real certificate being presented unmodified.
- A **blue-green pair of backend processes** behind that front door, refreshed on a schedule with a health-gated cutover, so the long-lived Xray process is periodically recycled without ever dropping the public listener.
- Camouflage tuned against DPI/active-probe detection: standard port 443, a real CDN's SNI, `xtls-rprx-vision` flow (so encrypted payload is byte-indistinguishable from ordinary TLS), high-entropy `shortId`s, and connection logging disabled.

A fourth component chains two of the nodes together — a client connects to the node with the best network path, which re-encapsulates the connection to a second node's egress, letting the client keep a specific exit IP without eating that node's own poor upstream peering.

None of the real IPs, REALITY keys, client UUIDs, or `shortId`s from the live deployment are in this repo. Every config example uses placeholder values — see [Security notes](#security-notes--what-was-redacted).

## Why this exists

This started as personal infrastructure (get around a censoring network, at first for myself and then for family/friends) and turned into an ongoing systems-engineering exercise: multi-host state tracking, protocol-level fingerprint reduction, an actual production incident with a real root cause, and a zero-downtime deployment mechanism built because a naive "restart the proxy" approach was measurably degrading upload throughput over time.

## Architecture

```
                      ┌─────────────────────────────────────────┐
                      │              Client (Clash /             │
                      │           Shadowrocket / mihomo)          │
                      └───────────────┬───────────────────────────┘
                                       │  VLESS + REALITY, TCP, xtls-rprx-vision
              ┌────────────────────────┼────────────────────────┐
              ▼                        ▼                        ▼
   ┌─────────────────────┐  ┌─────────────────────┐  ┌─────────────────────┐
   │   Node A (Tokyo)     │  │  Node B (Malaysia)   │  │   Node C (Japan)     │
   │   nginx stream :443   │  │  HAProxy TCP :443     │  │  nginx stream :443   │
   │  (Docker, host net)   │  │  (Plesk sw-nginx has   │  │  (podman, no SELinux │
   │                       │  │   no stream module —   │  │   booleans needed)   │
   │  ┌─────┐   ┌─────┐    │  │   HAProxy owns 443)    │  │  ┌─────┐   ┌─────┐    │
   │  │xray-a│   │xray-b│   │  │  ┌─────┐   ┌─────┐    │  │  │xray-a│   │xray-b│   │
   │  │:1443 │   │:2443 │   │  │  │xray-a│   │xray-b│   │  │  │:1443 │   │:2443 │   │
   │  │active│   │drain │   │  │  │:1443 │   │:2443 │   │  │  │active│   │drain │   │
   │  └─────┘   └─────┘    │  │  └─────┘   └─────┘    │  │  └─────┘   └─────┘    │
   └───────────┬───────────┘  └───────────┬───────────┘  └───────────┬───────────┘
               │ daily cron flip (04:30 local): restart standby,     │
               │ liveness-probe it, only then swap the active symlink │
               └───────────────────────────┬──────────────────────────┘
                                            │
                          ┌─────────────────┴─────────────────┐
                          │   Optional: cross-region relay      │
                          │   Node C entry → re-encapsulate →   │
                          │   Node B egress (raw TCP fast path, │
                          │   dedicated relay-only client)      │
                          └──────────────────────────────────────┘
```

Each node is generated from the **same config template** (`/etc/xray-docker/config.json` in the live deployment) via a small backend generator that produces two byte-identical backends differing only in listen port — so REALITY keys, client UUIDs, and `shortId`s can never drift between the active and standby backend.

### Why three different front-door technologies for three nodes

Node A and Node C could both run nginx with `libnginx-mod-stream`. Node B is a Plesk-managed CloudLinux box whose bundled `sw-nginx` build has no compatible stream module available in its enabled repos, and installing a parallel nginx would fight Plesk's own management of the box — so Node B uses HAProxy for the identical TCP-passthrough blue-green pattern instead. Recognizing *when a host's constraints mean the "consistent" solution is wrong* was as much a part of this project as the design itself.

## Highlights

### 1. DPI-evasion protocol hardening (before → after)

The original deployment ran on a non-standard port with a nearly brute-forceable `shortId` and no traffic-shape camouflage. It was hardened in a single measured pass:

| Parameter | Before | After | Why it matters |
|---|---|---|---|
| Listening port | `8443` | `443` | Removes the "non-standard HTTPS port" signal that flags a host for deeper DPI |
| SNI / borrowed cert | a well-known REALITY target | a mainstream CDN domain, TLS 1.3 | Avoids client-side cert warnings, blends into ordinary CDN traffic |
| Flow control | *(none)* | `xtls-rprx-vision` | Encrypted payload byte-pattern becomes indistinguishable from real TLS |
| `shortId` entropy | 1 value, 2 hex chars | 5 values, 8 bytes each | A 256-attempt brute force becomes a 5×2⁶⁴ one |
| Access logging | enabled | disabled | No connection record survives if the host is ever seized/imaged |
| Runtime isolation | single systemd process | container/process pinned to an image digest | Rollback is "start the old process again," not "rebuild from scratch" |

The rollout kept the old listener alive during the transition, migrated client profiles in place, and preserved the previous runtime as a cold rollback path rather than deleting it — see [`docs/upgrade-log.md`](docs/upgrade-log.md) for the full before/after diagrams and settings table.

### 2. Zero-downtime blue-green refresh, adapted to two different TCP front doors

Long-lived Xray processes accumulated enough session state that upload throughput measurably degraded over time; a naive periodic restart would drop every live session at once. The fix: two backend processes per node behind a TCP-passthrough front door, one `active`, one `backup`/draining, flipped daily by a script that **never flips to an unverified backend** — it restarts only the standby, TLS-probes it for the borrowed certificate, and only then swaps the active symlink and reloads the front door. Established sessions ride out the old worker generation and drain naturally (Xray's own idle-connection timeout does the rest); a refresh in steady state drops close to zero live sessions. Full design, the nginx `stream{}` block rationale (timeouts, keepalive, why `worker_shutdown_timeout` must stay unset), and the rollback plan are in [`docs/blue-green-deployment.md`](docs/blue-green-deployment.md) — the actual flip scripts and front-door configs run in production are in [`deploy/`](deploy/): [nginx](deploy/nginx/) + [Docker](deploy/xray443-flip-nginx-docker.sh) on Node A, [nginx](deploy/nginx/) + [podman](deploy/xray443-flip-nginx-podman.sh) on Node C, [HAProxy](deploy/haproxy/) + [its own flip script](deploy/xray443-flip-haproxy.sh) on Node B, and the [backend generator](deploy/backends/regen-backends.py) that keeps both blue and green backends byte-identical.

### 3. A real production incident and its root cause

One node's blue-green front door quietly failed after a few days, and the "obvious" explanation (config drift) turned out to be wrong. The actual chain: the kernel OOM killer selected the proxy process under memory pressure → the host's legacy web server, configured to auto-restart on failure, immediately re-bound the now-free port → the proxy's own restart attempts then failed with "address already in use" and gave up after a few tries → separately, the host's control-panel logrotate hook was independently capable of reviving that same web server even when its systemd unit was disabled. The fix that actually stuck was masking the web server's unit outright (a hard block that a config-management panel's internal restart calls can't override), not just stopping it. Full RCA narrative in [`docs/architecture.md`](docs/architecture.md).

### 4. Cross-region relay chaining for a specific exit IP with better throughput

One node's own peering path from the client's network is poor (a real inter-carrier congestion issue, confirmed by isolating the proxy stack entirely and comparing raw `scp` throughput over the same path), even though that node's own uplink bandwidth is fine. A second node happens to have much better peering *to* the first node. Rather than accept the slow path, traffic is relayed: client → better-peered node (dedicated relay-only inbound, its own REALITY keypair) → re-encapsulated as a raw TCP client of the target node's egress-only fast path → target node's IP. The relay client is a separate, independently revocable credential from normal end-user clients. Root-caused with `traceroute` and paired raw-socket throughput tests before building the relay, not assumed. The relay entry's actual Xray config template, systemd unit, and the relay-aware backend generator (which gives each blue-green backend a second, REALITY-free inbound just for the relay's server-to-server leg) are in [`deploy/relay/`](deploy/relay/), [`deploy/systemd/xray-relay.service`](deploy/systemd/xray-relay.service), and [`deploy/backends/regen-backends-with-relay.py`](deploy/backends/regen-backends-with-relay.py).

### 5. A small, safe Python control-plane CLI

[`vpn_user_manager.py`](vpn_user_manager.py) — SSHes to a node, adds/lists/removes REALITY clients with atomic config writes (`jq` + backup + validate + restart + verify, never a bare overwrite), derives the REALITY public key from the private key server-side, and prints both a scannable QR code and a raw share link. Bootstraps its own throwaway virtualenv for the `qrcode` dependency if it isn't already installed, so the script has zero setup steps beyond Python + SSH access.

[`update_profile.py`](update_profile.py) — reads a small per-client policy file (allow/block domain and IP lists) and compiles it into Xray `routing.rules` scoped per client via the `user` field, so individual clients can be sandboxed to specific destinations without affecting anyone else.

## Repository layout

```
.
├── README.md
├── LICENSE
├── vpn_user_manager.py            # add/list/remove REALITY clients over SSH
├── update_profile.py              # compile per-client routing policy into Xray config
├── convert_to_clash.py            # Shadowrocket rule-list -> Clash rules: YAML
├── xray_docker_config.example.json  # source-of-truth config template (placeholder keys/UUIDs)
├── docs/
│   ├── architecture.md            # per-node runtime inventory + the OOM/logrotate RCA
│   ├── upgrade-log.md             # the DPI-hardening before/after, with diagrams
│   ├── blue-green-deployment.md   # the zero-downtime refresh design in full
│   └── client-setup-guide.md      # the plain-language guide given to non-technical users
└── deploy/                        # the actual artifacts each node runs, sanitized in place
    ├── nginx/                     # stream front-door config (Node A / Node C)
    ├── haproxy/                   # TCP front-door config (Node B)
    ├── systemd/                   # podman-wrapped backend + relay unit templates
    ├── backends/                  # config generators (plain + relay-aware variants)
    ├── relay/                     # relay entry node's Xray config template
    ├── xray443-flip-nginx-docker.sh   # daily flip, Node A (Docker)
    ├── xray443-flip-nginx-podman.sh   # daily flip, Node C (podman)
    └── xray443-flip-haproxy.sh        # daily flip, Node B (HAProxy)
```

## Quickstart (adapting this to your own deployment)

This repo is a template, not a turnkey installer — REALITY deployments are inherently host-specific (which front-door technology is even installable depends on what your provider's control panel already owns). To stand up something similar:

1. Generate a fresh REALITY keypair (`xray x25519`) and a fresh set of high-entropy `shortId`s — never reuse the placeholder values in [`xray_docker_config.example.json`](xray_docker_config.example.json) or anything under [`deploy/`](deploy/).
2. Pick an SNI you camouflage as: a mainstream site that serves TLS 1.3 and that Xray doesn't warn about.
3. Deploy the config with whatever TCP-passthrough front door your host actually supports — [`deploy/nginx/`](deploy/nginx/) + [`deploy/xray443-flip-nginx-docker.sh`](deploy/xray443-flip-nginx-docker.sh)/[`-podman.sh`](deploy/xray443-flip-nginx-podman.sh), or [`deploy/haproxy/`](deploy/haproxy/) + [`deploy/xray443-flip-haproxy.sh`](deploy/xray443-flip-haproxy.sh) if nginx's stream module isn't available. Design rationale for every setting is in [`docs/blue-green-deployment.md`](docs/blue-green-deployment.md).
4. Point `vpn_user_manager.py --host <your-host> --user <your-ssh-user>` at it to manage clients.

## Security notes — what was redacted

This is a sanitized copy of a real, currently-operated deployment. Every server IP, REALITY private/public key, client UUID, `shortId`, and non-standard SSH port from the live configuration has been replaced with an obviously-fake placeholder (`203.0.113.x` documentation-range addresses, `<...>` tokens, or clearly-labeled example values) — none of the values in this repo will connect to anything. Generated client-profile artifacts, a QR code that encoded a live credential, and a large third-party ad-block rule list were excluded entirely rather than redacted in place.

## License

MIT — see [LICENSE](LICENSE).
