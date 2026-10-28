#!/usr/bin/env bash
# run.sh <ffi: base|patched> <scenario> [reps] [PEER_ID=..]: fresh phone container per run, shared hub.
set -uo pipefail
H=$(cd "$(dirname "$0")" && pwd)
BINS=$(cd ${BINS_DIR:-$H/../bins} && pwd)
FFI=$1; SC=$2; REPS=${3:-1}
docker network inspect etnet >/dev/null 2>&1 || docker network create etnet >/dev/null
if ! docker ps --format '{{.Names}}' | grep -qx hub; then
  docker run -d --rm --name hub --network etnet --cap-add NET_ADMIN --device /dev/net/tun \
    -v $BINS:/bins:ro -v $H:/h:ro et-build bash /h/hub.sh >/dev/null
  sleep 3
fi
CRED_FILE=$H/.cred
if [[ ! -s $CRED_FILE ]]; then
  docker exec hub /bins/base/easytier-cli -p 127.0.0.1:15888 credential generate --ttl 864000 --credential-id phone-test --reusable false \
    | sed -n 's/.*credential_secret:[[:space:]]*\([^[:space:]]*\).*/\1/p' > $CRED_FILE
fi
for i in $(seq 1 $REPS); do
  docker run --rm --network etnet --cap-add NET_ADMIN -e CRED="$(cat $CRED_FILE)" -e FFI=/bins/$FFI/libeasytier_ffi.so \
    -e PEER_ID="${PEER_ID:-}" -e RUST_LOG=warn -v $BINS:/bins:ro -v $H:/h:ro et-build python3 /h/phone.py $SC 2>/dev/null | grep scenario \
    | sed "s/^/{\"ffi\":\"$FFI\",\"peer_id\":\"${PEER_ID:-random}\",\"rep\":$i} /"
done
