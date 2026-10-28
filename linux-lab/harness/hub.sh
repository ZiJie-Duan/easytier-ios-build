#!/usr/bin/env bash
# The hub: upstream behaviour (unpatched build), secure mode, TUN at 10.144.144.50, HTTP on :80.
set -euo pipefail
BIN=${BIN:-/bins/base}
mkdir -p /run/et
python3 -m http.server 80 --bind 0.0.0.0 --directory /tmp >/dev/null 2>&1 &
exec $BIN/easytier-core --network-name easytier-net --network-secret hub-secret --secure-mode \
  --ipv4 10.144.144.50/24 --listeners tcp://0.0.0.0:11010 --hostname hub \
  --rpc-portal 127.0.0.1:15888 --credential-file /run/et/credentials.json --console-log-level warn
