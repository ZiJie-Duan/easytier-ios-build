import Foundation
import Network
import Security

// `EASYTIER_FFI_VENDORED` is defined by EasyTier.podspec only when
// Frameworks/EasyTierFFI.xcframework exists at `pod install` time. Without it the
// module still compiles and reports `isFrameworkLinked == false`.
#if EASYTIER_FFI_VENDORED
import EasyTierFFI
#endif

/// Upper bound for `collect_network_infos`. We only ever run one instance, but a
/// stale one must still fit so it can be freed.
private let maxCollectedInstances = 8

/**
 The one EasyTier instance of the app, shared by the JS module (`EasyTierModule`)
 and the launch hook (`EasyTierAppDelegateSubscriber`), which starts the tunnel
 from the saved config before the JS bundle has even loaded (M22-6).

 Threading: every FFI call and every field below is only touched on `queue`, a
 private serial queue — never the main thread or the JS thread.

 Memory: every C string handed out by the library is released with `free_string`.
 */
final class EasyTierCore {
  static let shared = EasyTierCore()

  let queue = DispatchQueue(label: "expo.modules.easytier.ffi", qos: .userInitiated)

  // --- state owned by `queue` ---
  private(set) var instanceName: String?
  private var runningToml: String?
  var redactions: [String] = []

  /// Called on `queue` after the network path changed (and the tunnel was restarted).
  var onPathChange: (([String: Any]) -> Void)?

  private let pathMonitor = NWPathMonitor()
  private var lastPath: String?
  private var pathReconnect: DispatchWorkItem?

  private init() {
    pathMonitor.pathUpdateHandler = { [weak self] path in
      self?.queue.async { self?.pathChangedOnQueue(path) }
    }
    pathMonitor.start(queue: queue)
  }

  static var isFrameworkLinked: Bool {
    #if EASYTIER_FFI_VENDORED
    return true
    #else
    return false
    #endif
  }

  /// What this binary can do beyond a plain start / stop (M22-6).
  static var features: [String] {
    isFrameworkLinked ? ["nativeRestart", "pathRestart", "launchStart", "keepSameConfig"] : []
  }

  // MARK: - Lifecycle (queue only)

  /// Starts the instance, or keeps the running one when it runs this exact config
  /// (the launch hook may have started it already). Returns true when kept.
  @discardableResult
  func startOnQueue(toml: String, instanceName: String) throws -> Bool {
    if self.instanceName == instanceName, runningToml == toml, isAliveOnQueue(instanceName) {
      return true
    }
    _ = stopAllOnQueue()

    #if EASYTIER_FFI_VENDORED
    let rc = toml.withCString { run_network_instance($0) }
    if rc != 0 {
      throw EasyTierCoreError.start(lastErrorMessage())
    }
    #endif

    self.instanceName = instanceName
    runningToml = toml
    return false
  }

  /// Stops every instance. Returns an error message on failure.
  @discardableResult
  func stopAllOnQueue() -> String? {
    instanceName = nil
    runningToml = nil
    pathReconnect?.cancel()
    pathReconnect = nil

    #if EASYTIER_FFI_VENDORED
    let rc = retain_network_instance(nil, 0)
    if rc != 0 {
      return lastErrorMessage()
    }
    #endif
    return nil
  }

  /// Restarts the running config: a new instance (a new random peer id) dials the hub at once.
  /// Measured against an unpatched hub (M22-6), this is the fastest way back from a dead path:
  /// ~0.1 s plus the handshake. Keeping the peer id was slower (2–9 s): the hub keeps sending to
  /// the old, silently dead connection of that id until it re-picks its link every 5 s.
  func restartOnQueue() throws {
    guard let name = instanceName, let toml = runningToml else {
      throw EasyTierCoreError.notRunning
    }
    _ = stopAllOnQueue()
    #if EASYTIER_FFI_VENDORED
    let rc = toml.withCString { run_network_instance($0) }
    if rc != 0 {
      throw EasyTierCoreError.start(lastErrorMessage())
    }
    #endif
    instanceName = name
    runningToml = toml
  }

  func validate(toml: String) throws {
    #if EASYTIER_FFI_VENDORED
    let rc = toml.withCString { parse_config($0) }
    if rc != 0 {
      throw EasyTierCoreError.config(lastErrorMessage())
    }
    #endif
  }

  // MARK: - Network path (queue only)

  /// A different way out (Wi-Fi ↔ cellular, another Wi-Fi, back from no network): the
  /// connection to the hub is very likely dead, but nothing tells EasyTier until 5
  /// heartbeats are lost (13.8 s measured). Restart right away instead.
  private func pathChangedOnQueue(_ path: NWPath) {
    let interfaces = path.availableInterfaces.map { "\($0.type)" }.joined(separator: ",")
    let signature = "\(path.status)|\(interfaces)|\(path.isExpensive)"
    let previous = lastPath
    lastPath = signature
    guard let previous = previous, previous != signature, path.status == .satisfied, instanceName != nil else {
      return
    }
    pathReconnect?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self = self, self.instanceName != nil else { return }
      var restarted = true
      do { try self.restartOnQueue() } catch { restarted = false }
      self.onPathChange?(["path": signature, "previous": previous, "restarted": restarted])
    }
    pathReconnect = work
    // Hand-overs come in bursts (the new interface appears, then the old one leaves).
    queue.asyncAfter(deadline: .now() + .milliseconds(300), execute: work)
  }

  // MARK: - Status (queue only)

  func collectStatusOnQueue() -> [String: Any?] {
    var status: [String: Any?] = [
      "instanceName": instanceName,
      "running": false,
      "infoJson": nil,
      "error": nil,
    ]

    #if EASYTIER_FFI_VENDORED
    guard let name = instanceName else {
      return status
    }
    if let infoJson = infoJsonOnQueue(name) {
      status["infoJson"] = redact(infoJson)
      // Whether the instance is actually healthy is decided in JS from the JSON
      // (`running`, `error_msg`); here it only means "the instance exists".
      status["running"] = true
    } else {
      status["error"] = "EasyTier instance '\(name)' is not running"
    }
    #endif

    return status
  }

  private func isAliveOnQueue(_ name: String) -> Bool {
    infoJsonOnQueue(name) != nil
  }

  private func infoJsonOnQueue(_ name: String) -> String? {
    #if EASYTIER_FFI_VENDORED
    let capacity = maxCollectedInstances
    var buffer = [KeyValuePair](repeating: KeyValuePair(), count: capacity)
    let count = Int(collect_network_infos(&buffer, capacity))
    if count < 0 {
      return nil
    }
    var infoJson: String?
    for entry in buffer.prefix(min(count, capacity)) {
      var key: String?
      if let keyPtr = entry.key {
        key = String(cString: keyPtr)
      }
      if let valuePtr = entry.value, key == name {
        infoJson = String(cString: valuePtr)
      }
      free_string(entry.key)
      free_string(entry.value)
    }
    return infoJson
    #else
    return nil
    #endif
  }

  // MARK: - Launch config (Keychain)

  private static let keychainService = "expo.modules.easytier"
  private static let keychainAccount = "launch-config"

  /// Saves (or with nil clears) the config the launch hook starts with. It holds the
  /// credential key, so it lives in the Keychain, this device only.
  func setLaunchConfig(toml: String?, instanceName: String?) {
    let base: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: EasyTierCore.keychainService,
      kSecAttrAccount as String: EasyTierCore.keychainAccount,
    ]
    SecItemDelete(base as CFDictionary)
    guard let toml = toml, let instanceName = instanceName,
          let data = try? JSONSerialization.data(withJSONObject: ["toml": toml, "instanceName": instanceName]) else {
      return
    }
    var item = base
    item[kSecValueData as String] = data
    item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    SecItemAdd(item as CFDictionary, nil)
  }

  private func launchConfig() -> (toml: String, instanceName: String)? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: EasyTierCore.keychainService,
      kSecAttrAccount as String: EasyTierCore.keychainAccount,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: AnyObject?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
          let data = result as? Data,
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: String],
          let toml = object["toml"], let name = object["instanceName"] else {
      return nil
    }
    return (toml, name)
  }

  /// App launch: start the saved config at once, ~0.5–1.5 s before JS would (bundle load,
  /// Keychain reads, React mount). JS later calls `start` with the same config and keeps it.
  func startFromLaunchConfig() {
    guard EasyTierCore.isFrameworkLinked else { return }
    queue.async {
      guard self.instanceName == nil, let saved = self.launchConfig() else { return }
      _ = try? self.startOnQueue(toml: saved.toml, instanceName: saved.instanceName)
    }
  }

  // MARK: - Errors

  /// Reads (and frees) EasyTier's last error message. The library keeps the last
  /// message forever, so only call this right after a call returned -1.
  func lastErrorMessage() -> String {
    #if EASYTIER_FFI_VENDORED
    var pointer: UnsafePointer<CChar>?
    get_error_msg(&pointer)
    guard let messagePointer = pointer else {
      return "Unknown EasyTier error"
    }
    let message = String(cString: messagePointer)
    free_string(messagePointer)
    return redact(EasyTierCore.stripConfigEcho(message))
    #else
    return "EasyTier is not linked"
    #endif
  }

  /// EasyTier's config parser echoes the whole TOML (including the credential key)
  /// in its error context: "failed to parse config file: <toml>". Drop that echo
  /// but keep the "Caused by:" part, which holds the actual parse error.
  private static func stripConfigEcho(_ message: String) -> String {
    let marker = "failed to parse config file: "
    guard let markerRange = message.range(of: marker) else {
      return message
    }
    let head = message[..<markerRange.upperBound]
    if let causeRange = message.range(of: "Caused by:", range: markerRange.upperBound..<message.endIndex) {
      return String(head) + "<config redacted>\n\n" + String(message[causeRange.lowerBound...])
    }
    return String(head) + "<config redacted>"
  }

  func redact(_ text: String) -> String {
    var result = text
    for secret in redactions where !secret.isEmpty {
      result = result.replacingOccurrences(of: secret, with: "<redacted>")
    }
    return result
  }
}

enum EasyTierCoreError: Error {
  case start(String)
  case config(String)
  case notRunning

  var message: String {
    switch self {
    case .start(let m), .config(let m): return m
    case .notRunning: return "EasyTier is not running"
    }
  }
}
