import ExpoModulesCore
import Foundation

// `EASYTIER_FFI_VENDORED` is defined by EasyTier.podspec only when
// Frameworks/EasyTierFFI.xcframework exists at `pod install` time. Without it the
// module still compiles and reports `isFrameworkLinked == false`, so a dev build
// without the (large, uncommitted) framework keeps working.
#if EASYTIER_FFI_VENDORED
import EasyTierFFI
#endif

private let statusEventName = "onStatusChange"
/// Upper bound for `collect_network_infos`. We only ever run one instance, but a
/// stale one (e.g. from a JS reload) must still fit so it can be freed.
private let maxCollectedInstances = 8
private let defaultPollIntervalMs = 2000
private let minPollIntervalMs = 500

/**
 Runs EasyTier in-process through its C FFI (`easytier_ffi.h`).

 Threading: every FFI call happens on `ffiQueue`, a private serial queue, never on
 the main thread or the JS thread. All mutable state below is only touched on that
 queue. The FFI calls are synchronous; `run_network_instance` returns once the
 instance's tokio tasks are spawned on EasyTier's own threads.

 Memory: every C string handed out by the library (`get_error_msg`,
 `collect_network_infos`) is released with `free_string`.
 */
public class EasyTierModule: Module {
  private let ffiQueue = DispatchQueue(label: "expo.modules.easytier.ffi", qos: .utility)

  // --- state owned by ffiQueue ---
  private var instanceName: String?
  private var redactions: [String] = []
  private var pollIntervalMs = defaultPollIntervalMs
  private var hasListeners = false
  private var pollTimer: DispatchSourceTimer?

  public func definition() -> ModuleDefinition {
    Name("EasyTier")

    Events(statusEventName)

    /// Whether the EasyTierFFI static library was linked into this binary.
    Constant("isFrameworkLinked") { () -> Bool in
      EasyTierModule.isFrameworkLinked
    }

    OnCreate {
      // A JS reload recreates this module while EasyTier's global instance manager
      // (Rust statics) keeps running. Stop anything left over so `start` never hits
      // "instance already exists" and no orphaned tunnel keeps running unobserved.
      self.ffiQueue.async {
        _ = self.stopAllOnQueue()
      }
    }

    OnDestroy {
      self.ffiQueue.sync {
        _ = self.stopAllOnQueue()
      }
    }

    OnStartObserving(statusEventName) {
      self.ffiQueue.async {
        self.hasListeners = true
        self.updatePollingOnQueue()
      }
    }

    OnStopObserving(statusEventName) {
      self.ffiQueue.async {
        self.hasListeners = false
        self.updatePollingOnQueue()
      }
    }

    /// Validates a TOML config with `parse_config` without starting anything.
    AsyncFunction("validateConfig") { (toml: String, redactions: [String]) in
      try self.ensureLinked()
      try EasyTierModule.validate(toml: toml, redactions: redactions)
    }
    .runOnQueue(ffiQueue)

    /// (Re)starts the single EasyTier instance. Any running instance is stopped first.
    AsyncFunction("start") { (toml: String, instanceName: String, pollIntervalMs: Int, redactions: [String]) in
      try self.ensureLinked()
      try self.startOnQueue(
        toml: toml,
        instanceName: instanceName,
        pollIntervalMs: pollIntervalMs,
        redactions: redactions
      )
    }
    .runOnQueue(ffiQueue)

    /// Stops every EasyTier instance (`retain_network_instance` with length 0).
    AsyncFunction("stop") {
      try self.ensureLinked()
      if let error = self.stopAllOnQueue() {
        throw Exception(name: "EasyTierStopFailed", description: error, code: "ERR_EASYTIER_STOP")
      }
      self.emitStatusOnQueue()
    }
    .runOnQueue(ffiQueue)

    /// Returns `{ instanceName?, running, infoJson?, error? }`; `infoJson` is the raw
    /// `NetworkInstanceRunningInfo` JSON, parsed on the JS side.
    AsyncFunction("getStatus") { () -> [String: Any] in
      return self.collectStatusOnQueue().compactMapValues { $0 }
    }
    .runOnQueue(ffiQueue)
  }

  // MARK: - Lifecycle (ffiQueue only)

  private func startOnQueue(toml: String, instanceName: String, pollIntervalMs: Int, redactions: [String]) throws {
    self.redactions = redactions.filter { !$0.isEmpty }
    self.pollIntervalMs = max(pollIntervalMs, minPollIntervalMs)

    // Idempotent restart: tear down whatever is running (ours or a stale one).
    _ = stopAllOnQueue()

    #if EASYTIER_FFI_VENDORED
    let rc = toml.withCString { run_network_instance($0) }
    if rc != 0 {
      let message = EasyTierModule.lastErrorMessage(redactions: self.redactions)
      throw Exception(name: "EasyTierStartFailed", description: message, code: "ERR_EASYTIER_START")
    }
    #endif

    self.instanceName = instanceName
    updatePollingOnQueue()
    emitStatusOnQueue()
  }

  /// Stops every instance and polling. Returns an error message on failure.
  @discardableResult
  private func stopAllOnQueue() -> String? {
    instanceName = nil
    updatePollingOnQueue()

    #if EASYTIER_FFI_VENDORED
    let rc = retain_network_instance(nil, 0)
    if rc != 0 {
      return EasyTierModule.lastErrorMessage(redactions: redactions)
    }
    #endif
    return nil
  }

  private func updatePollingOnQueue() {
    let shouldPoll = EasyTierModule.isFrameworkLinked && hasListeners && instanceName != nil

    if shouldPoll, pollTimer == nil {
      let timer = DispatchSource.makeTimerSource(queue: ffiQueue)
      let interval = DispatchTimeInterval.milliseconds(pollIntervalMs)
      timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(250))
      timer.setEventHandler { [weak self] in
        self?.emitStatusOnQueue()
      }
      timer.resume()
      pollTimer = timer
    } else if !shouldPoll, let timer = pollTimer {
      timer.cancel()
      pollTimer = nil
    }
  }

  private func emitStatusOnQueue() {
    guard hasListeners else {
      return
    }
    sendEvent(statusEventName, collectStatusOnQueue())
  }

  // MARK: - Status (ffiQueue only)

  private func collectStatusOnQueue() -> [String: Any?] {
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

    let capacity = maxCollectedInstances
    var buffer = [KeyValuePair](repeating: KeyValuePair(), count: capacity)
    let count = Int(collect_network_infos(&buffer, capacity))
    if count < 0 {
      status["error"] = EasyTierModule.lastErrorMessage(redactions: redactions)
      return status
    }

    var infoJson: String?
    for entry in buffer.prefix(min(count, capacity)) {
      var key: String?
      if let keyPtr = entry.key {
        key = String(cString: keyPtr)
      }
      if let valuePtr = entry.value, key == name {
        infoJson = EasyTierModule.redact(String(cString: valuePtr), redactions)
      }
      free_string(entry.key)
      free_string(entry.value)
    }

    if let infoJson = infoJson {
      status["infoJson"] = infoJson
      // Whether the instance is actually healthy is decided in JS from the JSON
      // (`running`, `error_msg`); here it only means "the instance exists".
      status["running"] = true
    } else {
      status["error"] = "EasyTier instance '\(name)' is not running"
    }
    #endif

    return status
  }

  // MARK: - FFI helpers

  private static var isFrameworkLinked: Bool {
    #if EASYTIER_FFI_VENDORED
    return true
    #else
    return false
    #endif
  }

  private func ensureLinked() throws {
    if !EasyTierModule.isFrameworkLinked {
      throw Exception(
        name: "EasyTierUnavailable",
        description: "EasyTierFFI.xcframework is not linked into this build. Run modules/easytier/scripts/fetch-xcframework.js, then rebuild the app.",
        code: "ERR_EASYTIER_UNAVAILABLE"
      )
    }
  }

  private static func validate(toml: String, redactions: [String]) throws {
    #if EASYTIER_FFI_VENDORED
    let rc = toml.withCString { parse_config($0) }
    if rc != 0 {
      let message = lastErrorMessage(redactions: redactions.filter { !$0.isEmpty })
      throw Exception(name: "EasyTierInvalidConfig", description: message, code: "ERR_EASYTIER_CONFIG")
    }
    #endif
  }

  /// Reads (and frees) EasyTier's last error message. The library keeps the last
  /// message forever, so only call this right after a call returned -1.
  private static func lastErrorMessage(redactions: [String]) -> String {
    #if EASYTIER_FFI_VENDORED
    var pointer: UnsafePointer<CChar>?
    get_error_msg(&pointer)
    guard let messagePointer = pointer else {
      return "Unknown EasyTier error"
    }
    let message = String(cString: messagePointer)
    free_string(messagePointer)
    return redact(stripConfigEcho(message), redactions)
    #else
    return "EasyTier is not linked"
    #endif
  }

  /// EasyTier's config parser echoes the whole TOML (including `network_secret`)
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

  private static func redact(_ text: String, _ redactions: [String]) -> String {
    var result = text
    for secret in redactions where !secret.isEmpty {
      result = result.replacingOccurrences(of: secret, with: "<redacted>")
    }
    return result
  }
}
