# easytier-ios-build

Builds [EasyTier](https://github.com/EasyTier/EasyTier)'s C FFI (`easytier-contrib/easytier-ffi`) as an iOS static library and packages it as `EasyTierFFI.xcframework`, ready to embed in an iOS app or an Expo native module.

Upstream EasyTier does not ship iOS builds; this repo only adds the build scripts and does not modify EasyTier's source beyond two Cargo.toml tweaks at build time:

- `crate-type = ["staticlib"]` (iOS apps cannot load third-party dylibs)
- trimmed feature set (default `tun,magic-dns,smoltcp,socks5,kcp,zstd`), aimed at in-process `no_tun` mode with `port_forward` — no Network Extension needed (`tun`/`magic-dns` are compiled in only because the iOS code path requires them; see Build notes)

## Output

| File | Contents |
|---|---|
| `EasyTierFFI.xcframework.zip` | `ios-arm64` (device) + `ios-arm64-simulator` static libs, `easytier_ffi.h`, `module.modulemap` (Swift: `import EasyTierFFI`) |
| `BUILD_INFO.txt` | EasyTier commit, features, rustc version, library sizes, and the system libraries to link (`native_static_libs`) |

Pushes to `main` upload a workflow artifact; tags `v*` also create a GitHub Release.

## Building

On GitHub: Actions → **build-ios** → *Run workflow*, optionally overriding the EasyTier ref and features.

Locally on a Mac (Xcode, rustup, protoc installed):

```bash
./scripts/build.sh
EASYTIER_REF=v2.6.4 FEATURES=tun,magic-dns,smoltcp,socks5,kcp,zstd ./scripts/build.sh
```

## Build notes

Results for EasyTier `v2.6.4` (commit `8428a89`), rustc 1.95.0, `IPHONEOS_DEPLOYMENT_TARGET=15.1`, runner `macos-15`.

### Release

- Release page: https://github.com/ZiJie-Duan/easytier-ios-build/releases/tag/v2.6.4-1
- Download: https://github.com/ZiJie-Duan/easytier-ios-build/releases/download/v2.6.4-1/EasyTierFFI.xcframework.zip
- sha256: `0c1bb7912ded9fe47d25b2cbb410d407a19aea7514fd01b4090d40edbc5b0090`

### Problems hit and fixes

1. **rust-cache `key` invalid** — the key was `${EASYTIER_REF}-${FEATURES}` and contained commas. Fix: a workflow step computes `CACHE_KEY` with commas replaced by `_`.
2. **`easytier` failed to compile without `tun`/`magic-dns`** (`cannot find type ArcNicCtx`, `NicCtx`, no `clear_nic_ctx` / `use_new_nic_ctx` / `create_magic_dns_runner` / `get_nic_ctx`). EasyTier's `build.rs` defines a `mobile` cfg alias for `target_os = "ios"`, and the `#[cfg(mobile)]` code (`Instance::setup_nic_ctx_for_mobile` in `instance/instance.rs`, `run_routine_for_mobile` in `launcher.rs`) uses TUN and Magic DNS items that are only gated on `feature = "tun"` / `feature = "magic-dns"`. Fix: enable `tun` and `magic-dns`. No source patch needed. Both stay inactive at runtime: with `no_tun = true` and no `set_tun_fd` call, no NIC is created and the Magic DNS runner is never started.
3. **Symbol check failed although the symbols were present** — `nm -gU lib.a | grep -q` under `set -o pipefail` fails when `grep -q` exits early and `nm` gets SIGPIPE. Fix: write `nm` output to `build/logs/<target>.symbols.txt` and grep that file.

There were no other iOS-specific compile problems: `--locked` resolved fine, and `tun-easytier`, `kcp-sys`, `zstd-sys`, `ring` and `hickory` all built for `aarch64-apple-ios` and `aarch64-apple-ios-sim`.

### Final configuration

- Features: `tun,magic-dns,smoltcp,socks5,kcp,zstd` with `default-features = false`. Not included: `wireguard`, `websocket`, `quic`, `faketcp`, `aes-gcm`, `openssl-crypto`. Peers must therefore be reached over `tcp://` or `udp://`, not `ws`/`wss`/`quic`/`wg`. `ring` is still linked in through other dependencies.
- `native-static-libs` (link these in the app; Xcode links most of them by default):
  `-framework CoreFoundation -framework SystemConfiguration -lc -liconv -lSystem -lm`
- Static lib sizes: `ios-arm64` 31.3 MB, `ios-arm64-simulator` 31.1 MB (before stripping; most of this is dropped at app link time). The zip is about 19.7 MB.
- Exported C API: `parse_config run_network_instance retain_network_instance collect_network_infos set_tun_fd get_error_msg free_string`.

### Linking caveats

- Minimum iOS version is 15.1 (`IPHONEOS_DEPLOYMENT_TARGET`).
- No bitcode (Xcode 14+ no longer supports it anyway).
- Device and simulator are arm64 only, so there is no x86_64 simulator slice.
- **Duplicate-symbol risk:** the archive exports unprefixed C symbols from vendored **zstd** (`ZSTD_*`, `HUF_*`, `FSE_*`, `ZDICT_*`, ...) and **kcp** (`ikcp_*`). If another library in the app also links zstd or kcp statically, the link fails with duplicate symbols, or one copy silently wins. `ring` symbols are version-prefixed (`ring_core_0_17_14_*`) and are safe. The archive also exports `_rust_eh_personality`, which clashes if the app links a second Rust staticlib. In that case, build both into a single staticlib.
- Never call `free()` on strings the library returns. Call `free_string()` instead.

## API

See [`include/easytier_ffi.h`](include/easytier_ffi.h): `run_network_instance(toml)`, `retain_network_instance`, `collect_network_infos`, `parse_config`, `set_tun_fd`, `get_error_msg`, `free_string`.

## License

Build scripts: MIT. The produced binaries contain EasyTier, which is licensed under LGPL-3.0.
