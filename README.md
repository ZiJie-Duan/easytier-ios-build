# easytier-ios-build

Builds [EasyTier](https://github.com/EasyTier/EasyTier)'s C FFI (`easytier-contrib/easytier-ffi`) as an iOS static library and packages it as `EasyTierFFI.xcframework`, ready to embed in an iOS app or an Expo native module.

Upstream EasyTier does not ship iOS builds; this repo only adds the build scripts and does not modify EasyTier's source beyond two Cargo.toml tweaks at build time:

- `crate-type = ["staticlib"]` (iOS apps cannot load third-party dylibs)
- trimmed feature set (default `smoltcp,socks5,kcp,zstd`), aimed at in-process `no_tun` mode with `port_forward` — no TUN, no Network Extension

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
EASYTIER_REF=v2.6.4 FEATURES=smoltcp,socks5,kcp,zstd ./scripts/build.sh
```

## API

See [`include/easytier_ffi.h`](include/easytier_ffi.h): `run_network_instance(toml)`, `retain_network_instance`, `collect_network_infos`, `parse_config`, `set_tun_fd`, `get_error_msg`, `free_string`.

## License

Build scripts: MIT. The produced binaries contain EasyTier, which is licensed under LGPL-3.0.
