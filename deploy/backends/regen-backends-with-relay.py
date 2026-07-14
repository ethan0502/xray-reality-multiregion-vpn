#!/usr/bin/env python3
"""Regenerate blue-green backend configs from the live 443 config.

Variant used on the node that also serves as a relay egress (see
docs/architecture.md, "Cross-region relay chaining"). Each backend gets two
inbounds:
  1. The public-facing REALITY inbound (same identity as source config.json,
     listen/port only differ) -- serves real end-user clients crossing censorship.
  2. A raw-TCP, no-TLS inbound on a separate port -- server-to-server fast path
     for the relay hop, which never crosses a censoring network and doesn't
     need REALITY's camouflage/handshake overhead. Uses the same dedicated
     relay-chain client identity as the REALITY inbound, just without
     encryption or flow (both require a TLS-backed transport).
"""
import copy
import json
from pathlib import Path

SOURCE = Path("/etc/xray-docker/config.json")
OUT_DIR = Path("/etc/xray-docker/backends")
BACKENDS = {
    "xray-a": {"reality_port": 1443, "raw_port": 1444},
    "xray-b": {"reality_port": 2443, "raw_port": 2444},
}
RELAY_CLIENT_ID = "<JP_RELAY_CLIENT_UUID>"  # placeholder -- generate your own with uuidgen


def raw_inbound(port):
    return {
        "tag": "relay-raw",
        "listen": "127.0.0.1",
        "port": port,
        "protocol": "vless",
        "settings": {
            "clients": [{"id": RELAY_CLIENT_ID, "email": "relay-raw"}],
            "decryption": "none",
        },
        "streamSettings": {"network": "tcp", "security": "none"},
    }


def backend_config(source, reality_port, raw_port):
    cfg = copy.deepcopy(source)
    if not cfg.get("inbounds"):
        raise SystemExit("source config has no inbounds")
    inbound = cfg["inbounds"][0]
    inbound["listen"] = "127.0.0.1"
    inbound["port"] = reality_port
    cfg["inbounds"] = [inbound, raw_inbound(raw_port)]
    return cfg


def main():
    source = json.loads(SOURCE.read_text())
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    for name, ports in BACKENDS.items():
        target = OUT_DIR / f"{name}.json"
        data = backend_config(source, ports["reality_port"], ports["raw_port"])
        target.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
        print(f"wrote {target} (reality 127.0.0.1:{ports['reality_port']}, raw 127.0.0.1:{ports['raw_port']})")


if __name__ == "__main__":
    main()
