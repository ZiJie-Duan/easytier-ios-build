# easytier-ios-build

Builds [EasyTier](https://github.com/EasyTier/EasyTier)'s C FFI (`easytier-contrib/easytier-ffi`) as an iOS static library and packages it as `EasyTierFFI.xcframework`, ready to embed in an iOS app or an Expo native module.

Upstream EasyTier does not ship iOS builds; this repo adds the build scripts, two Cargo.toml tweaks at build time, and one small source patch (`patches/`, see below):

- `crate-type = ["staticlib"]` (iOS apps cannot load third-party dylibs)
- trimmed feature set (default `tun,magic-dns,smoltcp,socks5,kcp,zstd,aes-gcm`), aimed at in-process `no_tun` mode with `port_forward` — no Network Extension needed (`tun`/`magic-dns` are compiled in only because the iOS code path requires them; see Build notes)

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
EASYTIER_REF=v2.6.4 FEATURES=tun,magic-dns,smoltcp,socks5,kcp,zstd,aes-gcm ./scripts/build.sh
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

### Source patch: credential nodes from TOML (`patches/credential-toml.patch`, since v2.6.4-3)

EasyTier v2.6.4 can admit a node with a per-user **credential** instead of the network secret (`easytier-cli credential generate` on an admin node, `easytier-core --secure-mode --credential <key>` on the new node); revoking the credential removes that node from the whole network. But `TomlConfigLoader::new_from_str` — the only config path the FFI has — always rebuilds the network identity from `network_secret` (empty when absent), so a credential node started from TOML presents a digest of the empty secret and is rejected (`invalid proof and unknown credential`). It also never derives `secure_mode.local_public_key`, which the CLI does.

The patch (in `easytier/src/common/config.rs`, `new_from_str`):

- `[secure_mode] enabled = true` → fill in missing keys with `process_secure_mode_cfg`, like the CLI;
- no `network_secret` + `secure_mode.local_private_key` → `NetworkIdentity::new_credential`, like `--credential`.

Configs with a `network_secret` behave exactly as before. Verified on Linux with the FFI built from the same features (Python ctypes, same calls as the Swift bridge): a TOML credential node joins in ~2 s, reaches a service through `port_forward`, is dropped by every node within seconds of `credential revoke`, and reconnects normally after a restart. Without the patch the same TOML is rejected.

Secure mode is all-or-nothing: secure and non-secure nodes reject each other's handshake (`unexpected packet type during handshake`), so a network switches every node at once.

### Final configuration

- Features: `tun,magic-dns,smoltcp,socks5,kcp,zstd,aes-gcm` with `default-features = false`. Not included: `wireguard`, `websocket`, `quic`, `faketcp`, `openssl-crypto`. Peers must therefore be reached over `tcp://` or `udp://`, not `ws`/`wss`/`quic`/`wg`. `ring` is still linked in through other dependencies.
- **`aes-gcm` is required to join a standard network.** EasyTier's default `encryption_algorithm` is `aes-gcm` only when one of `aes-gcm` / `wireguard` / `openssl-crypto` is compiled in; without them it silently falls back to `xor`. Desktop builds (default features include `wireguard`) then cannot decrypt the phone's packets: the handshake and pings succeed, but route sync never completes and the phone gets no routes (seen with release `v2.6.4-1`). The pure-Rust `aes-gcm` cipher uses the same `StandardAeadTail` layout as the `ring` cipher desktop nodes use, so the two interoperate.
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

### Source patch: fast path (`patches/fast-path.patch`, since v2.6.4-4)

For an app that restarts its node often (phone: suspended, network changes) and reaches services through `port_forward`:

- **Dial at once.** The manual connector only dialled on its 1 s tick: a new peer waited up to a second, a lost connection up to a second more. It now also scans when a connector is added and when a connection closes (event-driven scans at most every 500 ms, so a node rejected right after its handshake does not redial in a loop).
- **No direct dial into our own virtual network.** A forwarded connection to an address in the node's own subnet that has no route yet (start-up, restart) was dialled over the host network, where it never answers, and hung 10 s. It now waits for the route (≤ 5 s, polled every 25 ms) and fails fast after that.
- **smoltcp reactor lost wake-up.** `Reactor::notify` used `notify_waiters()`, which wakes nobody when the reactor loop is not parked in its `select!` (sending, polling): the wake-up was lost until the next packet or timer. `notify_one()` stores a permit; the loop is the only waiter.
- **Accept loops never spin.** iOS can invalidate a suspended app's listening sockets; `accept` then fails at once, forever, and the port-forward loop spun a core. It now backs off and rebinds the listener after 3 failures; the SOCKS5 portal loop backs off too. Accepted local sockets get `TCP_NODELAY`.

Measured on Linux (Docker, the FFI driven through Python ctypes the way the iOS app calls it, an unpatched v2.6.4 hub in secure mode with a non-reusable credential; LAN round trip ≈ 0):

| | v2.6.4-3 | v2.6.4-4 |
|---|---|---|
| start → first HTTP response through the forward | 0.20 s | 0.03–0.11 s |
| first request while the forward listens but has no route yet | 0.09–1.16 s | 0.03 s |
| restart after the link died silently (network change), new id **below** the old one | 0.20 s | 0.11 s |
| link silently dead, no restart (until EasyTier notices) | 13.8 s | — |

Tried and dropped: reconnecting with the same peer id (closing the connections and redialling) and a fixed `peer_id` across restarts were *slower* (2–9 s): the hub keeps sending to the old, silently dead connection of that peer id until it re-picks the peer's connection (every 5 s). A restart with a new id is the fastest way back.

**The new id must be lower than the old one.** With a non-reusable credential the hub keeps only the *lowest* peer id per credential while both nodes look alive (`collect_non_reusable_credential_owners` in `peers/peer_ospf_route.rs`). A higher id is accepted and closed again within 5 ms (FIN + RST) on every dial, until the hub times the old node out: 7–10 s, which happened to about half of the random-id restarts. A first 3-run sample had missed this. Measured with `linux-lab/`: a lower id recovered in 0.11 s 5 of 5 times, a higher one took 7–8 s 2 of 2 times. The Expo module (`expo-module/easytier/ios/EasyTierCore.swift`) writes a `peer_id` at the top of the TOML on every start. It picks a random value in a 2^20 window just below the previous id, which it saves in UserDefaults, and goes back to a high random id after 120 s without a sign of life.

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

## Expo module CI

[`.github/workflows/expo-module-ios.yml`](.github/workflows/expo-module-ios.yml) checks that the app's local Expo native module ([`expo-module/easytier/`](expo-module/easytier): `EasyTierModule.swift`, `EasyTier.podspec`, `expo-module.config.json`, `scripts/fetch-xcframework.js`, `xcframework.json`) builds and runs inside a real **Expo SDK 57** iOS app. It runs on `macos-26`, because SDK 57 needs Xcode 26.4 or newer and `macos-15` only goes up to 26.3. It triggers on `workflow_dispatch` and on pushes to `main` that touch `expo-module/**`, `smoke/**` or the workflow file.

**Tier 1: build.** The job scaffolds a fresh app with `npx create-expo-app@latest e2e --template blank-typescript@sdk-57`. It copies the module to `e2e/modules/easytier` (autolinked from `modules/`) and sets `ios.bundleIdentifier` and the app's ATS setting (`NSAllowsLocalNetworking`). Then it runs `fetch-xcframework.js --strict`, which downloads the pinned v2.6.4-1 zip and checks its sha256, followed by `expo prebuild -p ios --clean` and `pod install`. Finally it builds with `xcodebuild -configuration Release -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO`. The job fails if any of these is missing:
- `-DEASYTIER_FFI_VENDORED` in the EasyTier pod xcconfig and in the Swift compiler invocations of the `EasyTier` pod. This means the real FFI path was compiled, not the stub.
- a clean link, with no `Undefined symbols` or `duplicate symbol`. The app binary exports `_run_network_instance`, `_collect_network_infos`, `_retain_network_instance`, `_parse_config`, `_get_error_msg` and `_free_string`.

**Tier 2: run.** The harness [`expo-module/harness/App.tsx`](expo-module/harness/App.tsx) replaces `App.tsx` and calls `requireNativeModule('EasyTier')` directly. It runs these steps in order:
1. Calls `isFrameworkLinked`.
2. Calls `validateConfig` with a good config, then with a bad one. The bad config must reject, and the error must not contain the secret.
3. Calls `start` with the same TOML as [`smoke/trinity.toml`](smoke/trinity.toml).
4. Listens for `onStatusChange` events and polls `getStatus` until `10.144.144.50` appears in the routes.
5. Calls `fetch('http://127.0.0.1:18081/hello')` through the port forward.
6. Calls `stop`.

On the host side, [`expo-module/harness/server.py`](expo-module/harness/server.py) serves `127.0.0.1:8080`, the service behind the `no_tun` hub, and collects the JSON result the app POSTs to `127.0.0.1:18999` (the simulator shares the host's loopback). The hub is `smoke --hub-only smoke/hub.toml <seconds>`, started with `xcrun simctl spawn` right before `simctl launch`. The test passes only if every check in the result is true. The result, the hub, server and app logs, a screenshot, `pod-install.log` and `xcodebuild.log` are uploaded as the `expo-module-logs` artifact.

Results ([run 37229800882](https://github.com/ZiJie-Duan/easytier-ios-build/actions/runs/37229800882), Xcode 26.6, iOS 26.5 simulator):

| Check | Result |
|---|---|
| `EASYTIER_FFI_VENDORED` active (3 Swift compiler invocations, `-target arm64-apple-ios16.4-simulator`) | PASS |
| Release `.app` links, FFI symbols present, app is 46 MB with a 19 MB binary | PASS |
| `isFrameworkLinked === true`, `validateConfig` good/bad, secret redacted in the error | PASS |
| `start`; `my_node_info.virtual_ipv4` = 10.144.144.149; hub `10.144.144.50` in routes after 1.1 s | PASS |
| `fetch` via `127.0.0.1:18081` returns HTTP 200 `hello-from-hub ...` | PASS |
| `onStatusChange` events with `infoJson`; `stop` then `getStatus().running === false` | PASS |

One fix was needed. Without it, a generic-simulator Release build also compiles the pod for `x86_64`, and that fails with `no such module 'EasyTierFFI'` because the xcframework has no x86_64 simulator slice. The podspec in `expo-module/easytier` therefore sets `EXCLUDED_ARCHS[sdk=iphonesimulator*] = x86_64` for the pod and for the app target. Device builds are not affected.

To run it, open Actions, choose **expo-module-ios** and click **Run workflow**, or use `gh workflow run expo-module-ios.yml`. A run takes about 15 minutes.

## API

See [`include/easytier_ffi.h`](include/easytier_ffi.h): `run_network_instance(toml)`, `retain_network_instance`, `collect_network_infos`, `parse_config`, `set_tun_fd`, `get_error_msg`, `free_string`.

## License

Build scripts: MIT. The produced binaries contain EasyTier, which is licensed under LGPL-3.0.
