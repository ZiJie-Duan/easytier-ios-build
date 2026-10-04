#!/usr/bin/env bash
# Build EasyTier's FFI crate as an iOS static library and package it as
# dist/EasyTierFFI.xcframework. Needs macOS with Xcode, rustup and protoc.
#
# Env overrides:
#   EASYTIER_REF                git tag/branch of EasyTier to build (default v2.6.4)
#   FEATURES                    easytier cargo features, comma separated
#   TARGETS                     rust targets, space separated
#   IPHONEOS_DEPLOYMENT_TARGET  minimum iOS version
set -euo pipefail

EASYTIER_REF=${EASYTIER_REF:-v2.6.4}
# no_tun + port_forward needs smoltcp/socks5; kcp and zstd match the server side.
FEATURES=${FEATURES:-smoltcp,socks5,kcp,zstd}
TARGETS=${TARGETS:-"aarch64-apple-ios aarch64-apple-ios-sim"}
export IPHONEOS_DEPLOYMENT_TARGET=${IPHONEOS_DEPLOYMENT_TARGET:-15.1}

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SRC=$ROOT/build/EasyTier
OUT=$ROOT/dist
LOGS=$ROOT/build/logs

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

log "EasyTier $EASYTIER_REF | features: $FEATURES | targets: $TARGETS | iOS >= $IPHONEOS_DEPLOYMENT_TARGET"

if [[ ! -d $SRC/.git ]]; then
  log "Cloning EasyTier $EASYTIER_REF"
  mkdir -p "$ROOT/build"
  git clone --depth 1 --branch "$EASYTIER_REF" https://github.com/EasyTier/EasyTier.git "$SRC"
fi
EASYTIER_COMMIT=$(git -C "$SRC" rev-parse --short HEAD)

log "Patching easytier-ffi: staticlib + trimmed features"
git -C "$SRC" checkout -- easytier-contrib/easytier-ffi/Cargo.toml
python3 - "$SRC/easytier-contrib/easytier-ffi/Cargo.toml" "$FEATURES" <<'EOF'
import sys
path, features = sys.argv[1], sys.argv[2]
s = open(path).read()

old_crate = 'crate-type = ["cdylib"]'
assert s.count(old_crate) == 1, "crate-type line changed upstream"
s = s.replace(old_crate, 'crate-type = ["staticlib"]')

old_dep = 'easytier = { path = "../../easytier" }'
assert s.count(old_dep) == 1, "easytier dependency line changed upstream"
feature_list = ", ".join(f'"{f.strip()}"' for f in features.split(",") if f.strip())
s = s.replace(old_dep, f'easytier = {{ path = "../../easytier", default-features = false, features = [{feature_list}] }}')

open(path, "w").write(s)
EOF
git -C "$SRC" diff --stat

cd "$SRC"
# rust-toolchain.toml in the EasyTier repo pins the compiler; add targets to that toolchain.
rustup target add $TARGETS
rustc --version

mkdir -p "$LOGS"
rm -rf "$OUT"
mkdir -p "$OUT"

XC_ARGS=()
for target in $TARGETS; do
  log "Building $target"
  cargo rustc --release --locked -p easytier-ffi --lib --target "$target" \
    -- --print=native-static-libs 2>&1 | tee "$LOGS/$target.log"

  lib=$SRC/target/$target/release/libeasytier_ffi.a
  [[ -f $lib ]] || { echo "missing $lib"; exit 1; }

  log "Checking exported symbols in $target"
  for sym in parse_config run_network_instance retain_network_instance \
             collect_network_infos set_tun_fd get_error_msg free_string; do
    nm -gU "$lib" 2>/dev/null | grep -q " _${sym}$" || { echo "symbol $sym not exported"; exit 1; }
  done
  echo "all 7 symbols present"

  XC_ARGS+=(-library "$lib" -headers "$ROOT/include")
done

log "Creating xcframework"
xcodebuild -create-xcframework "${XC_ARGS[@]}" -output "$OUT/EasyTierFFI.xcframework"

NATIVE_LIBS=$(grep -h "native-static-libs:" "$LOGS"/*.log | head -1 | sed 's/.*native-static-libs: //')

cat > "$OUT/BUILD_INFO.txt" <<EOF
easytier_ref=$EASYTIER_REF
easytier_commit=$EASYTIER_COMMIT
features=$FEATURES
targets=$TARGETS
ios_deployment_target=$IPHONEOS_DEPLOYMENT_TARGET
rustc=$(rustc --version)
native_static_libs=$NATIVE_LIBS
EOF
for target in $TARGETS; do
  echo "size_$target=$(du -h "$SRC/target/$target/release/libeasytier_ffi.a" | cut -f1)" >> "$OUT/BUILD_INFO.txt"
done

cd "$OUT"
ditto -c -k --sequesterRsrc --keepParent EasyTierFFI.xcframework EasyTierFFI.xcframework.zip
shasum -a 256 EasyTierFFI.xcframework.zip > EasyTierFFI.xcframework.zip.sha256

log "Done"
cat BUILD_INFO.txt
ls -lh "$OUT"
