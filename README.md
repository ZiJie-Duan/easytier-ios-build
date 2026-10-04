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

## Simulator smoke test

Workflow [`smoke-ios-sim`](.github/workflows/smoke-ios-sim.yml) (manual, or on push to `main` touching `smoke/**`) checks the published release zip on a real iOS Simulator. It uses the zip as an app would. No Mac is needed.

1. It downloads the release zip and checks its sha256.
2. It compiles [`smoke/main.swift`](smoke/main.swift), which uses `import EasyTierFFI` through the xcframework's `module.modulemap`:
   ```bash
   SIM=EasyTierFFI.xcframework/ios-arm64-simulator
   xcrun --sdk iphonesimulator swiftc -target arm64-apple-ios15.1-simulator -O \
     -I "$SIM/Headers" -L "$SIM" -leasytier_ffi \
     -liconv -framework SystemConfiguration -framework CoreFoundation \
     smoke/main.swift -o smoke
   codesign -s - -f smoke
   ```
3. It boots an iPhone simulator and runs `xcrun simctl spawn <udid> smoke smoke/hub.toml smoke/trinity.toml`.

The program makes the same FFI calls as Trinity's Swift bridge: `parse_config`, `run_network_instance`, `collect_network_infos` with a `KeyValuePair` buffer plus `free_string`, `retain_network_instance(nil, 0)` to stop, and `get_error_msg` plus `free_string`. It runs two instances in one process:

- **hub** ([`smoke/hub.toml`](smoke/hub.toml)): `10.144.144.50/24`, `no_tun`, listens on `tcp://127.0.0.1:11010`, no peers. It stands in for the server node.
- **trinity** ([`smoke/trinity.toml`](smoke/trinity.toml)): the app's exact `buildEasyTierToml` output with a dummy secret. It uses `10.144.144.149/24` and `peer tcp://127.0.0.1:11010`, with `port_forward 127.0.0.1:18081 -> 10.144.144.50:8080`, `no_tun` and `listeners = []`.
- A TCP echo server listens on `127.0.0.1:8080`.

### Results

Run [37226634830](https://github.com/ZiJie-Duan/easytier-ios-build/actions/runs/37226634830): release `v2.6.4-1` on an iPhone SE (3rd gen) simulator, iOS 26.2, with Xcode on `macos-15` and iOS SDK 18.5.

| Check | Result |
|---|---|
| `import EasyTierFFI` via modulemap, compile + link with the flags above | PASS |
| `parse_config` on the app's TOML / on garbage (`rc=-1`, readable message) | PASS / PASS |
| a. start hub | PASS |
| b. start trinity; a second start of the same name is rejected (`instance already exists`) | PASS |
| c. `collect_network_infos` returns `hub` and `trinity`, both valid JSON | PASS |
| c. trinity `my_node_info.virtual_ipv4` = `10.144.144.149/24`, `running: true`, `error_msg: null` | PASS |
| c. hub `10.144.144.50/24` appears in trinity's `peer_route_pairs` after 1.0 to 1.5 s (cost 1, direct `tcp`, `latency_us` about 280) | PASS |
| c. hub sees trinity `10.144.144.149/24` | PASS |
| d. TCP connect to `127.0.0.1:18081` (port-forward listener) | PASS |
| e. `ping` echoed through `18081 -> 10.144.144.50:8080 -> echo server` (KCP path, default) | PASS |
| e. 3000-byte echo through the same path | PASS |
| e. echo with hub `disable_kcp_input = true` (smoltcp TCP path; trinity sees `feature_flag.kcp_input=false`) | PASS |
| f. `retain_network_instance(nil, 0)` returns 0, then `collect` returns 0 instances and `18081` refuses connections | PASS |
| f. restart `trinity` under the same name after stop, then stop again | PASS |
| process exits with code 0 | PASS |

**Memory** (`task_info`, two instances in one process, the binary is about 18 MB):

| Point | phys_footprint | resident | threads |
|---|---|---|---|
| baseline | 10.5 MB | 35.5 MB | 1 |
| after start | 10.8 MB | 37.5 MB | 4 |
| after traffic | 15.0 MB | 47.1 MB | 15 |
| after stop | 14.1 MB | 47.0 MB | 3 |

`phys_footprint` is the number jetsam counts. EasyTier costs about 5 MB on top of the baseline, which is far below iOS limits even for an app extension.

**Raw `collect_network_infos` value for `trinity`** (trimmed; `routes[]` and `peers[]` repeat what is in `peer_route_pairs[]`):

```json
{"dev_name":"",
 "my_node_info":{"virtual_ipv4":{"address":{"addr":177246357},"network_length":24},"hostname":"ci-smoke",
   "version":"2.6.4-8428a89d~","ips":{"public_ipv4":null,"interface_ipv4s":[{"addr":3232251907}],"public_ipv6":null,"interface_ipv6s":[],"listeners":[]},
   "stun_info":{"udp_nat_type":0,"tcp_nat_type":3,"last_update_time":1791140357,"public_ip":["13.105.117.160"],"min_port":34575,"max_port":34575},
   "listeners":[{"url":"ring://8e267b1a-..."}],"vpn_portal_cfg":"","peer_id":611372365},
 "events":["{\"time\":\"2026-10-04T18:59:18.084697Z\",\"event\":{\"PeerAdded\":3220168421}}",
           "{\"time\":\"...18:59:18.082919Z\",\"event\":{\"Connecting\":\"tcp://127.0.0.1:11010\"}}",
           "{\"time\":\"...18:59:17.116337Z\",\"event\":{\"PortForwardAdded\":{...}}}", "..."],
 "peer_route_pairs":[{
   "route":{"peer_id":3220168421,"ipv4_addr":{"address":{"addr":177246258},"network_length":24},"next_hop_peer_id":3220168421,
            "cost":1,"path_latency":500,"proxy_cidrs":[],"hostname":"hub","version":"2.6.4-8428a89d~",
            "feature_flag":{"kcp_input":true,"quic_input":true,"...":"..."},"inst_id":"4808e31d-...","...":"..."},
   "peer":{"peer_id":3220168421,"conns":[{"conn_id":"65665999-...","tunnel":{"tunnel_type":"tcp",
            "local_addr":{"url":"tcp://127.0.0.1:49673"},"remote_addr":{"url":"tcp://127.0.0.1:11010"},"resolved_remote_addr":{"url":"tcp://127.0.0.1:11010"}},
            "stats":{"rx_bytes":4327,"tx_bytes":4742,"rx_packets":16,"tx_packets":18,"latency_us":279},
            "loss_rate":0.0,"is_client":true,"is_closed":false,"network_name":"trinity-smoke","...":"..."}],
          "default_conn_id":{"part1":1701206425,"...":"..."},"directly_connected_conns":[{"...":"..."}]}}],
 "routes":[...], "peers":[...],
 "running":true,"error_msg":null,"foreign_network_summary":{"info_map":{}}}
```

`177246357` is `0x0A909095`, which is 10.144.144.149, so `addr` is a big-endian u32. `routes` and `peers` both exist alongside `peer_route_pairs`. `events` is a list of JSON-encoded strings, **newest first**. `path_latency` was `500` on a loopback link whose measured RTT was 0.28 ms, so it is a routing weight, not a latency in milliseconds. Even with `listeners = []`, every instance gets an internal `ring://<inst_id>` listener. STUN worked from the simulator, so the public IP shows up.

### How `no_tun` handles inbound traffic (EasyTier v2.6.4 source, confirmed by the test)

- **Sender (the phone, `no_tun`)**: `port_forward` is served by `gateway/socks5.rs`. For each accepted connection it calls `PeerManager::check_allow_kcp_to_dst`. If the destination peer advertises `feature_flag.kcp_input` (the default) and the relay path allows it, the stream goes through the KCP proxy. Otherwise it is opened on the userspace smoltcp stack, and raw IPv4/TCP packets travel over the overlay. The test passed both ways.
- **Receiver with `no_tun`** (the in-process hub): TCP that arrives for the node's own virtual IP is terminated in userspace. For the TCP path this happens in `gateway/tcp_proxy.rs`, where `check_packet_from_peer` accepts `dst == own vIP` when `no_tun` is set and smoltcp terminates it. For KCP it happens in `kcp_proxy.rs`. In both cases the node then dials **`127.0.0.1:<port>`**, because `is_ip_local_virtual_ip` causes the address to be rewritten to loopback. The echo server saw connections from `127.0.0.1`. A `no_tun` node therefore accepts inbound connections on its vIP, but only for services listening on loopback.
- **Real server node `10.144.144.50`** (Linux, with TUN): the loopback rewrite applies only when `no_tun` is set. With KCP (the default), `KcpProxyDst` dials `10.144.144.50:8080` itself. Without KCP, the TCP packets are written to the TUN device and the kernel delivers them. Either way the service must listen on `0.0.0.0:8080` or `10.144.144.50:8080` (**not** only `127.0.0.1`), and the server's firewall must allow it on the TUN interface. The port must not be one of EasyTier's own listener ports or a protected RPC port (`should_deny_proxy`). Keeping `kcp_input` enabled on the server (the default) keeps the faster KCP path.

## API

See [`include/easytier_ffi.h`](include/easytier_ffi.h): `run_network_instance(toml)`, `retain_network_instance`, `collect_network_infos`, `parse_config`, `set_tun_fd`, `get_error_msg`, `free_string`.

## License

Build scripts: MIT. The produced binaries contain EasyTier, which is licensed under LGPL-3.0.
