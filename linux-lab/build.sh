#!/usr/bin/env bash
# Linux build of the patched tree: easytier-core / easytier-cli (hub) + easytier-ffi cdylib with the phone's features.
set -euo pipefail
cd /src
# Test builds only: no LTO, parallel codegen (behaviour is the same, the build is several times faster).
export CARGO_PROFILE_RELEASE_LTO=off CARGO_PROFILE_RELEASE_CODEGEN_UNITS=16 CARGO_PROFILE_RELEASE_STRIP=false
FEATURES=${FEATURES:-tun,magic-dns,smoltcp,socks5,kcp,zstd,aes-gcm}
command -v protoc >/dev/null && command -v mold >/dev/null || (apt-get update -qq && apt-get install -y -qq protobuf-compiler mold clang >/dev/null)
cargo build --release --locked -p easytier --bin easytier-core --bin easytier-cli
# FFI with the phone's feature set, built in its own target dir so feature unification with the bins does not differ.
sed -e 's|easytier = { path = "../../easytier" }|easytier = { path = "../../easytier", default-features = false, features = ['"$(echo $FEATURES | sed 's/\([^,]*\)/"\1"/g')"'] }|' \
  easytier-contrib/easytier-ffi/Cargo.toml > /tmp/ffi.toml
cp easytier-contrib/easytier-ffi/Cargo.toml /tmp/ffi.orig.toml
cp /tmp/ffi.toml easytier-contrib/easytier-ffi/Cargo.toml
trap 'cp /tmp/ffi.orig.toml /src/easytier-contrib/easytier-ffi/Cargo.toml' EXIT
cargo build --release --locked -p easytier-ffi --lib
mkdir -p /out && cp target/release/easytier-core target/release/easytier-cli target/release/libeasytier_ffi.so /out/ && ls -la /out
