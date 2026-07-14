# Benchmarks

Real speed-test data backing the throughput claims in the root [README](../README.md#benchmarks) and in [`docs/architecture.md`](../docs/architecture.md) ("Cross-region relay chaining"). Server IPs, client UUIDs, and the tester's local machine details were stripped from the raw output; the numbers themselves are unmodified.

This data was collected with the blue-green front door already live on every node — it's a steady-state, multi-node snapshot, not a before/after comparison. The separate observation that originally justified building blue-green (a bare process restart reliably restoring degraded upload throughput back to a tuned baseline) is a single-node data point from a different test run, described in [`docs/blue-green-deployment.md`](../docs/blue-green-deployment.md#motivation) rather than repeated here.

## Method

- Client vantage point: a Windows host on the operator's own LAN.
- Test runner: a temporary no-TUN Mihomo profile, run once per node, torn down afterward — nothing measured here rides the operator's normal daily VPN session. Each run restores the machine's normal Clash service after the temporary process exits.
- Nodes tested: Tokyo (two different client profiles), Malaysia (two different client identities), Japan direct, and the Japan-entry → Malaysia-egress relay chain.
- 3 repeated runs per node, 8 MiB download + 8 MiB upload per run, 5 latency samples per run.
- Download via a CDN speed-test endpoint; upload via a third-party echo endpoint — see the caveat below, upload numbers are noisier than download.

## Results

| Node | Exit region | Download (MiB/s) | Upload (MiB/s) | Latency (ms) | Runs |
|---|---|---|---|---|---|
| JP direct | Japan | 3.11 | 0.91 | 548 | 3/3 |
| Tokyo primary | Tokyo | 2.67 | 1.16 | 1182 | 3/3 |
| Tokyo (alt client) | Tokyo | 2.44 | 1.06 | 1144 | 3/3 |
| JP relay → Malaysia | Malaysia (via Japan relay) | 1.60 | 0.81 | 1581 | 3/3 |
| Malaysia (client A) | Malaysia | 0.87 | 0.38 | 1078 | 3/3 |
| Malaysia (client B) | Malaysia | 0.70 | 0.28 | 995 | 3/3 |

![Average throughput and latency per node](avg-bar.svg)

## Upload throughput around the blue-green cutover (Tokyo)

A separate real-world data point, unrelated to the repeated-run test above: three Ookla Speedtest runs from a phone on 5G through the Tokyo node's exit, spanning the hour the blue-green front door went live there. See the root [README's version of this section](../README.md#upload-throughput-around-the-blue-green-cutover) for the full table and chart, and [`docs/blue-green-deployment.md`](../docs/blue-green-deployment.md#motivation) for the degradation mechanism this is a real-world instance of. Timestamps were cross-checked against the node's own deployment artifacts (config file mtimes, flip log) rather than taken at face value.

## Files in this folder

| File | What it is |
|---|---|
| [`summary.csv`](summary.csv) | Compact per-node summary (download/upload/latency averages), repeated-run test. |
| [`summary.json`](summary.json) | Structured summary with per-node averages and medians, repeated-run test. |
| [`upload-recovery.svg`](upload-recovery.svg) | The three-point Tokyo upload chart above. |
| [`avg-bar.svg`](avg-bar.svg) | Average download, upload, and latency bar chart. |
| [`run-variability.svg`](run-variability.svg) | Run-to-run spread across the 3 repeats per node. |

Excluded from this repo: the raw per-run JSONL and the earlier single-run HTML/SVG report, because those baked real server IPs and the tester's local machine path directly into their contents rather than into easily-stripped fields.

## Reading these numbers

This is the actual data that drove the relay-chaining decision described in [`docs/architecture.md`](../docs/architecture.md): direct Malaysia throughput (0.70–0.87 MiB/s down) is well below Japan-direct (3.11 MiB/s down) despite Malaysia's own uplink being fine in isolation — the gap is inter-carrier peering quality on the path to Malaysia specifically, confirmed separately with raw (non-proxied) transfer tests over the same path. Relaying through Japan (1.60 MiB/s down while still exiting as the Malaysia IP) roughly doubles direct-Malaysia throughput without giving up the Malaysia exit IP the client actually needs — a real, measured improvement, not a full fix, since the client's own path to the relay's entry point is a separate bottleneck the relay doesn't touch.

The two Tokyo rows and two Malaysia rows are the same node tested with two different client identities/profiles in the same run, included to show run-to-run and profile-to-profile variance rather than a single cherry-picked number.

## Known caveats in this data

- **Upload numbers are noisier than download.** The upload target is a third-party echo endpoint, not a CDN; suspiciously similar upload figures across otherwise-different nodes suggest that endpoint itself may be part of what's capped, not pure path bandwidth. Download numbers (via a CDN) are more trustworthy.
- **Latency here includes the no-TUN Mihomo test harness overhead**, not just raw network RTT — treat these as relative-comparison numbers between nodes tested the same way, not absolute network latency.
- Small sample size (3 runs/node) — enough to see the relay-chaining effect clearly (2x+), not enough to treat single-digit-percent differences between nodes as significant.
