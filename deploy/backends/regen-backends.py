#!/usr/bin/env python3
"""Regenerate blue-green backend configs from the live 443 config.

Single source of truth: /etc/xray-docker/config.json (the identity clients use).
Backends are byte-for-byte identical to it except for the inbound listen
address/port, so REALITY keys, UUIDs, shortIds and flow never drift.

Run this (as root) after ANY change to the source config, then restart
whichever backend is currently the draining standby, and let the daily flip
pick up the other one -- or restart both during a maintenance window.
"""
import copy
import json

SRC = "/etc/xray-docker/config.json"
OUT = {
    "/etc/xray-docker/backends/xray-a.json": 1443,
    "/etc/xray-docker/backends/xray-b.json": 2443,
}

with open(SRC) as f:
    base = json.load(f)

# The live config has exactly one inbound (VLESS+REALITY on 0.0.0.0:443).
if len(base.get("inbounds", [])) != 1:
    raise SystemExit(f"expected exactly 1 inbound in {SRC}, got {len(base.get('inbounds', []))}")

for path, port in OUT.items():
    cfg = copy.deepcopy(base)
    cfg["inbounds"][0]["listen"] = "127.0.0.1"
    cfg["inbounds"][0]["port"] = port
    with open(path, "w") as f:
        json.dump(cfg, f, indent=2)
        f.write("\n")
    print(f"wrote {path} (127.0.0.1:{port})")
