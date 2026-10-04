// EasyTierFFI simulator smoke test.
//
// Runs inside an iOS Simulator (`xcrun simctl spawn booted smoke <hub.toml> <trinity.toml>`)
// and drives the FFI exactly like the Trinity app's Swift bridge
// (modules/easytier/ios/EasyTierModule.swift): `import EasyTierFFI` through the
// xcframework's module.modulemap, run_network_instance, collect_network_infos with a
// KeyValuePair buffer + free_string, retain_network_instance(nil, 0) to stop,
// get_error_msg + free_string for errors.
//
// Two instances run in this one process:
//   hub     - 10.144.144.50, no_tun, listens on tcp://127.0.0.1:11010 (stand-in for the server node)
//   trinity - the app's generated config: 10.144.144.149, peer tcp://127.0.0.1:11010,
//             port_forward 127.0.0.1:18081 -> 10.144.144.50:8080, no_tun
// A TCP echo server on 127.0.0.1:8080 plays the service behind the hub.

import Darwin
import EasyTierFFI
import Foundation

setvbuf(stdout, nil, _IONBF, 0)
signal(SIGPIPE, SIG_IGN)

let hubIp = "10.144.144.50"
let appIp = "10.144.144.149"
let forwardPort: UInt16 = 18081
let servicePort: UInt16 = 8080
let maxCollected = 8

var failures: [String] = []
var results: [(String, Bool, String)] = []

func log(_ s: String) { print(s) }

func check(_ name: String, _ ok: Bool, _ detail: String = "") {
  results.append((name, ok, detail))
  log("\(ok ? "PASS" : "FAIL") [\(name)] \(detail)")
  if !ok { failures.append(name) }
}

func info(_ name: String, _ detail: String) {
  results.append((name, true, "INFO " + detail))
  log("INFO [\(name)] \(detail)")
}

// MARK: - FFI helpers (mirror EasyTierModule.swift)

func lastError() -> String {
  var pointer: UnsafePointer<CChar>?
  get_error_msg(&pointer)
  guard let p = pointer else { return "<no error message>" }
  let message = String(cString: p)
  free_string(p)
  return message
}

func validate(_ toml: String) -> (Bool, String) {
  let rc = toml.withCString { parse_config($0) }
  return rc == 0 ? (true, "rc=0") : (false, "rc=\(rc) \(lastError())")
}

func start(_ toml: String) -> (Bool, String) {
  let rc = toml.withCString { run_network_instance($0) }
  return rc == 0 ? (true, "rc=0") : (false, "rc=\(rc) \(lastError())")
}

func stopAll() -> (Bool, String) {
  let rc = retain_network_instance(nil, 0)
  return rc == 0 ? (true, "rc=0") : (false, "rc=\(rc) \(lastError())")
}

/// Returns nil on FFI failure (count < 0).
func collect() -> [String: String]? {
  var buffer = [KeyValuePair](repeating: KeyValuePair(), count: maxCollected)
  let count = Int(collect_network_infos(&buffer, maxCollected))
  if count < 0 {
    log("collect_network_infos failed: \(lastError())")
    return nil
  }
  var out: [String: String] = [:]
  for entry in buffer.prefix(min(count, maxCollected)) {
    var key: String?
    if let k = entry.key { key = String(cString: k) }
    if let v = entry.value, let key = key { out[key] = String(cString: v) }
    free_string(entry.key)
    free_string(entry.value)
  }
  return out
}

// MARK: - JSON helpers (mirror modules/easytier/src/status.ts assumptions)

func jsonObject(_ s: String) -> [String: Any]? {
  guard let d = s.data(using: .utf8) else { return nil }
  return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
}

/// Ipv4Inet = { address: { addr: u32 big-endian }, network_length }
func inetString(_ v: Any?) -> String? {
  guard let inet = v as? [String: Any],
        let address = inet["address"] as? [String: Any],
        let addr = (address["addr"] as? NSNumber)?.uint32Value else { return nil }
  let ip = "\(addr >> 24).\((addr >> 16) & 0xff).\((addr >> 8) & 0xff).\(addr & 0xff)"
  if let len = inet["network_length"] as? NSNumber { return "\(ip)/\(len)" }
  return ip
}

func pretty(_ v: Any) -> String {
  guard JSONSerialization.isValidJSONObject(v),
        let d = try? JSONSerialization.data(withJSONObject: v, options: [.prettyPrinted, .sortedKeys]) else {
    return String(describing: v)
  }
  return String(data: d, encoding: .utf8) ?? ""
}

func routeIps(_ info: [String: Any]) -> [String] {
  var ips: [String] = []
  for pair in (info["peer_route_pairs"] as? [[String: Any]]) ?? [] {
    if let ip = inetString((pair["route"] as? [String: Any])?["ipv4_addr"]) { ips.append(ip) }
  }
  for route in (info["routes"] as? [[String: Any]]) ?? [] {
    if let ip = inetString(route["ipv4_addr"]), !ips.contains(ip) { ips.append(ip) }
  }
  return ips
}

// MARK: - Memory

func memory() -> String {
  var basic = mach_task_basic_info()
  var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
  let kr1 = withUnsafeMutablePointer(to: &basic) {
    $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
      task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
    }
  }
  var vm = task_vm_info_data_t()
  var vmCount = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
  let kr2 = withUnsafeMutablePointer(to: &vm) {
    $0.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
      task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &vmCount)
    }
  }
  let mb = { (b: UInt64) in String(format: "%.1f MB", Double(b) / 1_048_576) }
  let rss = kr1 == KERN_SUCCESS ? mb(UInt64(basic.resident_size)) : "?"
  let fp = kr2 == KERN_SUCCESS ? mb(UInt64(vm.phys_footprint)) : "?"
  var threads: thread_act_array_t?
  var threadCount: mach_msg_type_number_t = 0
  var nThreads = "?"
  if task_threads(mach_task_self_, &threads, &threadCount) == KERN_SUCCESS {
    nThreads = "\(threadCount)"
    vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threads)),
                  vm_size_t(Int(threadCount) * MemoryLayout<thread_t>.stride))
  }
  return "resident=\(rss) phys_footprint=\(fp) threads=\(nThreads)"
}

// MARK: - Sockets

func makeAddr(_ port: UInt16) -> sockaddr_in {
  var a = sockaddr_in()
  a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
  a.sin_family = sa_family_t(AF_INET)
  a.sin_port = port.bigEndian
  a.sin_addr.s_addr = inet_addr("127.0.0.1")
  return a
}

func setTimeouts(_ fd: Int32, seconds: Int) {
  var tv = timeval(tv_sec: seconds, tv_usec: 0)
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
  setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
}

var echoAccepted = 0
let echoLock = NSLock()

/// Echo server on 127.0.0.1:port; replies "ECHO:<data>". Returns false if bind fails.
func startEchoServer(port: UInt16) -> Bool {
  let fd = socket(AF_INET, SOCK_STREAM, 0)
  guard fd >= 0 else { return false }
  var yes: Int32 = 1
  setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
  var addr = makeAddr(port)
  let rc = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
  }
  guard rc == 0, listen(fd, 16) == 0 else {
    log("echo server bind/listen failed: errno=\(errno) \(String(cString: strerror(errno)))")
    close(fd)
    return false
  }
  Thread.detachNewThread {
    while true {
      var peer = sockaddr_in()
      var len = socklen_t(MemoryLayout<sockaddr_in>.size)
      let c = withUnsafeMutablePointer(to: &peer) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(fd, $0, &len) }
      }
      if c < 0 { continue }
      let from = "\(String(cString: inet_ntoa(peer.sin_addr))):\(UInt16(bigEndian: peer.sin_port))"
      echoLock.lock(); echoAccepted += 1; echoLock.unlock()
      log("echo server: accepted connection from \(from)")
      Thread.detachNewThread {
        setTimeouts(c, seconds: 15)
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
          let n = read(c, &buf, buf.count)
          if n <= 0 { break }
          let reply = Array("ECHO:".utf8) + buf[0..<n]
          _ = reply.withUnsafeBytes { write(c, $0.baseAddress, reply.count) }
        }
        close(c)
      }
    }
  }
  return true
}

/// Connects to 127.0.0.1:port. Returns fd or -errno.
func connectLocal(_ port: UInt16, timeoutSeconds: Int = 5) -> Int32 {
  let fd = socket(AF_INET, SOCK_STREAM, 0)
  guard fd >= 0 else { return -errno }
  setTimeouts(fd, seconds: timeoutSeconds)
  var addr = makeAddr(port)
  let rc = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
  }
  if rc != 0 {
    let e = errno
    close(fd)
    return -e
  }
  return fd
}

/// Sends `message` and waits for a reply. Returns (reply, errorDescription).
func roundTrip(_ fd: Int32, _ message: String, timeoutSeconds: Int) -> (String?, String) {
  setTimeouts(fd, seconds: timeoutSeconds)
  let bytes = Array(message.utf8)
  let w = bytes.withUnsafeBytes { write(fd, $0.baseAddress, bytes.count) }
  if w != bytes.count { return (nil, "write returned \(w) errno=\(errno) \(String(cString: strerror(errno)))") }
  var buf = [UInt8](repeating: 0, count: 4096)
  let n = read(fd, &buf, buf.count)
  if n > 0 { return (String(decoding: buf[0..<n], as: UTF8.self), "ok") }
  if n == 0 { return (nil, "connection closed by remote (EOF) without data") }
  return (nil, "read errno=\(errno) \(String(cString: strerror(errno)))")
}

func sleepMs(_ ms: Int) { usleep(useconds_t(ms * 1000)) }

// MARK: - Main

let args = CommandLine.arguments
guard args.count >= 3,
      let hubToml = try? String(contentsOfFile: args[1], encoding: .utf8),
      let appToml = try? String(contentsOfFile: args[2], encoding: .utf8) else {
  log("usage: smoke <hub.toml> <trinity.toml>  (could not read the TOML files)")
  exit(2)
}

log("== EasyTierFFI simulator smoke test ==")
log("process: \(ProcessInfo.processInfo.processName) os: \(ProcessInfo.processInfo.operatingSystemVersionString)")
log("env SIMULATOR_RUNTIME_VERSION=\(ProcessInfo.processInfo.environment["SIMULATOR_RUNTIME_VERSION"] ?? "-") SIMULATOR_MODEL_IDENTIFIER=\(ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "-")")
check("import", true, "import EasyTierFFI via module.modulemap compiled and linked")
log("memory baseline: \(memory())")

// 0. parse_config (app's validateConfig) + error path
let (v1, v1d) = validate(appToml)
check("parse_config(trinity.toml)", v1, v1d)
let (v2, v2d) = validate("this is = = not toml")
check("parse_config(invalid) fails with message", !v2 && v2d.count > 10, v2d.replacingOccurrences(of: "\n", with: " | ").prefix(200).description)

// a. hub
let (hOk, hDetail) = start(hubToml)
check("a. run_network_instance(hub)", hOk, hDetail)

// e (setup). echo server behind the hub's no_tun virtual IP
let echoUp = startEchoServer(port: servicePort)
check("e0. echo server on 127.0.0.1:\(servicePort)", echoUp)

// b. trinity (the app's exact config)
let (aOk, aDetail) = start(appToml)
check("b. run_network_instance(trinity)", aOk, aDetail)

// duplicate start must fail cleanly (the app's stop-then-start relies on this message path)
let (dupOk, dupDetail) = start(appToml)
check("b2. duplicate start rejected", !dupOk, dupDetail)

log("memory after start: \(memory())")

// c. collect until trinity sees the hub
var lastInfos: [String: String] = [:]
var appInfo: [String: Any]?
var hubInfo: [String: Any]?
var connectedAfter = -1.0
let t0 = Date()
while Date().timeIntervalSince(t0) < 20 {
  if let infos = collect() {
    lastInfos = infos
    appInfo = infos["trinity"].flatMap(jsonObject)
    hubInfo = infos["hub"].flatMap(jsonObject)
    if let a = appInfo, routeIps(a).contains(where: { $0.hasPrefix(hubIp + "/") || $0 == hubIp }) {
      connectedAfter = Date().timeIntervalSince(t0)
      break
    }
  }
  sleepMs(500)
}
check("c1. collect_network_infos returns both instances", lastInfos.keys.contains("trinity") && lastInfos.keys.contains("hub"),
      "keys=\(lastInfos.keys.sorted())")
check("c2. both values are valid JSON objects", appInfo != nil && hubInfo != nil)

if let a = appInfo {
  let myIp = inetString((a["my_node_info"] as? [String: Any])?["virtual_ipv4"])
  check("c3. trinity my_node_info.virtual_ipv4", myIp == appIp + "/24", "\(myIp ?? "nil")")
  check("c4. trinity running=true, no error_msg", (a["running"] as? Bool) == true && (a["error_msg"] as? String ?? "").isEmpty,
        "running=\(a["running"] ?? "nil") error_msg=\(a["error_msg"] ?? "nil")")
  let ips = routeIps(a)
  if let route = ((a["peer_route_pairs"] as? [[String: Any]])?.first?["route"] as? [String: Any]) {
    log("hub route feature_flag.kcp_input=\((route["feature_flag"] as? [String: Any])?["kcp_input"] ?? "nil") (true => port_forward uses the KCP stream proxy)")
  }
  check("c5. hub \(hubIp) among trinity's routes", connectedAfter >= 0,
        "routes=\(ips) after=\(String(format: "%.1fs", connectedAfter))")
  log("top-level keys (trinity): \(a.keys.sorted())")
  log("my_node_info keys: \(((a["my_node_info"] as? [String: Any])?.keys.sorted()) ?? [])")
  if let pair = (a["peer_route_pairs"] as? [[String: Any]])?.first {
    log("peer_route_pairs[0].route keys: \(((pair["route"] as? [String: Any])?.keys.sorted()) ?? [])")
    if let conn = ((pair["peer"] as? [String: Any])?["conns"] as? [[String: Any]])?.first {
      log("peer_route_pairs[0].peer.conns[0] keys: \(conn.keys.sorted())")
      log("  tunnel=\(pretty(conn["tunnel"] ?? "nil"))")
      log("  stats=\(pretty(conn["stats"] ?? "nil"))")
      log("  loss_rate=\(conn["loss_rate"] ?? "nil") is_closed=\(conn["is_closed"] ?? "nil")")
    } else {
      log("peer_route_pairs[0].peer.conns: none")
    }
  }
}
if let h = hubInfo {
  check("c6. hub sees trinity \(appIp)", routeIps(h).contains(where: { $0.hasPrefix(appIp) }), "routes=\(routeIps(h))")
}

// d. port-forward listener
var fwdFd: Int32 = -1
let tD = Date()
while Date().timeIntervalSince(tD) < 10 {
  fwdFd = connectLocal(forwardPort)
  if fwdFd >= 0 { break }
  sleepMs(500)
}
check("d. TCP connect 127.0.0.1:\(forwardPort) (port_forward bind)", fwdFd >= 0,
      fwdFd >= 0 ? "connected" : "errno=\(-fwdFd) \(String(cString: strerror(-fwdFd)))")

// e. data through the forward -> hub vIP 10.144.144.50:8080 -> (no_tun hub) 127.0.0.1:8080
if fwdFd >= 0 {
  let (reply, why) = roundTrip(fwdFd, "ping-trinity\n", timeoutSeconds: 12)
  close(fwdFd)
  echoLock.lock(); let accepted = echoAccepted; echoLock.unlock()
  check("e1. data round trip via port_forward -> \(hubIp):\(servicePort)", reply == "ECHO:ping-trinity\n",
        "reply=\(reply.map { $0.debugDescription } ?? "nil") (\(why)); echo server accepted \(accepted) conn(s)")
  // a second, bigger transfer on a new connection
  let fd2 = connectLocal(forwardPort)
  if fd2 >= 0 {
    let payload = String(repeating: "x", count: 3000) + "\n"
    setTimeouts(fd2, seconds: 12)
    let bytes = Array(payload.utf8)
    _ = bytes.withUnsafeBytes { write(fd2, $0.baseAddress, bytes.count) }
    var got = 0
    var buf = [UInt8](repeating: 0, count: 8192)
    let tE = Date()
    while got < bytes.count + 5, Date().timeIntervalSince(tE) < 12 {
      let n = read(fd2, &buf, buf.count)
      if n <= 0 { break }
      got += n
    }
    close(fd2)
    check("e2. 3000-byte echo via port_forward", got >= bytes.count + 5, "received \(got) of \(bytes.count + 5) bytes")
  }
}

log("memory after traffic: \(memory())")
if let raw = lastInfos["trinity"] {
  // refresh so the sample includes traffic counters
  let fresh = collect()?["trinity"] ?? raw
  log("----- RAW collect_network_infos JSON for instance 'trinity' -----")
  log(fresh)
  log("----- END RAW -----")
  if let obj = jsonObject(fresh) { log("----- PRETTY -----\n\(pretty(obj))\n----- END PRETTY -----") }
}
if let raw = lastInfos["hub"] {
  log("----- RAW collect_network_infos JSON for instance 'hub' -----")
  log(raw)
  log("----- END RAW -----")
}

// f. stop all, restart, stop again
let (s1, s1d) = stopAll()
check("f1. retain_network_instance(nil, 0)", s1, s1d)
sleepMs(1000)
let afterStop = collect()
check("f2. collect after stop returns 0 instances", afterStop?.isEmpty == true, "keys=\(afterStop.map { $0.keys.sorted() } ?? ["<error>"])")
let closedFd = connectLocal(forwardPort, timeoutSeconds: 2)
check("f3. port_forward listener closed after stop", closedFd < 0,
      closedFd < 0 ? "connect errno=\(-closedFd) \(String(cString: strerror(-closedFd)))" : "still accepting")
if closedFd >= 0 { close(closedFd) }
log("memory after stop: \(memory())")

let (r1, r1d) = start(appToml)
check("f4. restart trinity after stop (same instance_name)", r1, r1d)
sleepMs(1500)
check("f5. collect shows restarted trinity", collect()?.keys.contains("trinity") == true)
let (s2, s2d) = stopAll()
check("f6. stop again", s2, s2d)

// g. same forward with the hub refusing KCP input: forces the smoltcp TCP path
// (raw TCP/IP packets over the overlay instead of the KCP stream proxy).
let hubNoKcp = hubToml.replacingOccurrences(of: "[flags]\n", with: "[flags]\ndisable_kcp_input = true\n")
let (g1, g1d) = start(hubNoKcp)
let (g2, g2d) = start(appToml)
check("g1. restart hub (disable_kcp_input) + trinity", g1 && g2, "\(g1d) / \(g2d)")
var hubKcpFlag: Any = "unknown"
let tG = Date()
while Date().timeIntervalSince(tG) < 20 {
  if let a = collect()?["trinity"].flatMap(jsonObject),
     let route = ((a["peer_route_pairs"] as? [[String: Any]]) ?? []).map({ $0["route"] as? [String: Any] ?? [:] })
       .first(where: { inetString($0["ipv4_addr"])?.hasPrefix(hubIp + "/") == true }) {
    hubKcpFlag = (route["feature_flag"] as? [String: Any])?["kcp_input"] ?? "missing"
    if (hubKcpFlag as? Bool) == false { break }
  }
  sleepMs(500)
}
check("g2. trinity sees hub feature_flag.kcp_input=false", (hubKcpFlag as? Bool) == false, "kcp_input=\(hubKcpFlag)")
echoLock.lock(); let acceptedBefore = echoAccepted; echoLock.unlock()
var gFd: Int32 = -1
let tG2 = Date()
while Date().timeIntervalSince(tG2) < 10 {
  gFd = connectLocal(forwardPort)
  if gFd >= 0 { break }
  sleepMs(500)
}
if gFd >= 0 {
  let (reply, why) = roundTrip(gFd, "ping-smoltcp\n", timeoutSeconds: 12)
  close(gFd)
  echoLock.lock(); let acceptedAfter = echoAccepted; echoLock.unlock()
  check("g3. round trip via smoltcp TCP path", reply == "ECHO:ping-smoltcp\n",
        "reply=\(reply.map { $0.debugDescription } ?? "nil") (\(why)); new echo conns=\(acceptedAfter - acceptedBefore)")
} else {
  check("g3. round trip via smoltcp TCP path", false, "connect errno=\(-gFd)")
}
let (g4, g4d) = stopAll()
check("g4. stop", g4, g4d)
log("memory final: \(memory())")

log("== SUMMARY ==")
for (name, ok, detail) in results { log("\(ok ? "PASS" : "FAIL") \(name) — \(detail)") }
log(failures.isEmpty ? "RESULT: ALL PASS" : "RESULT: \(failures.count) FAILED: \(failures)")
exit(failures.isEmpty ? 0 : 1)
