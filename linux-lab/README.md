# Linux lab: fast-path timing

Drives `libeasytier_ffi.so` from Python the way the iPhone app does (same TOML shape: `no_tun`, secure mode,
credential, SOCKS5, one port forward) against an **unpatched** v2.6.4 hub in Docker, and times how long until an
HTTP request through the port forward answers again.

```bash
# 1. image + binaries (EasyTier source tree at $SRC, with or without patches/*.patch applied)
docker build -t et-build linux-lab
docker run --rm -v $SRC:/src -v $PWD/linux-lab/bins/patched:/out -v $PWD/linux-lab/build.sh:/b.sh:ro et-build bash /b.sh
#    (same again into bins/base from the unpatched tree; the hub always runs bins/base)
# 2. scenarios: cold | first-request | netchange-{restart,reconnect,nothing} | freeze-{restart,reconnect,nothing}
bash linux-lab/harness/run.sh patched netchange-restart 3
```

`run.sh` starts the hub container (`hub`, network `etnet`) once, issues a credential, and runs each repetition in
a fresh phone container. `BINS_DIR` overrides where the binaries are. A "network change" is simulated by silently
dropping the live TCP flow to the hub with iptables (no FIN, like a dead Wi-Fi path); new connections still work.
The peer list also contains `192.0.2.1` (TEST-NET-1, never reachable), standing in for the app's LAN-only address.
`PEER_ID` fixes the id of the first instance. With a random id, `netchange-restart` is slow about half the time:
the hub elects the lowest id per non-reusable credential (see the top-level README). Take enough repetitions.

Results (Docker bridge, RTT ≈ 0): see the fast-path section of the top-level README.
