import ExpoModulesCore
import Foundation

private let statusEventName = "onStatusChange"
private let pathEventName = "onPathChange"
private let defaultPollIntervalMs = 2000
private let minPollIntervalMs = 250

/**
 JS bridge to the app's one EasyTier instance (`EasyTierCore`, which owns the FFI).

 Threading: every call runs on the core's serial queue; the poll timer and the
 listener flag below are only touched there too.
 */
public class EasyTierModule: Module {
  private let core = EasyTierCore.shared

  // --- state owned by core.queue ---
  private var pollIntervalMs = defaultPollIntervalMs
  private var hasListeners = false
  private var pollTimer: DispatchSourceTimer?

  public func definition() -> ModuleDefinition {
    Name("EasyTier")

    Events(statusEventName, pathEventName)

    /// Whether the EasyTierFFI static library was linked into this binary.
    Constant("isFrameworkLinked") { () -> Bool in
      EasyTierCore.isFrameworkLinked
    }

    /// Capabilities beyond upstream EasyTier (absent on builds before M22-6).
    Constant("features") { () -> [String] in
      EasyTierCore.features
    }

    OnCreate {
      // A running instance is kept: the launch hook may have started it, and `start`
      // with the same config keeps it (a JS reload no longer restarts the tunnel).
      self.core.queue.async {
        self.core.onPathChange = { [weak self] info in
          guard let self = self, self.hasListeners else { return }
          self.sendEvent(pathEventName, info)
          self.emitStatusOnQueue()
        }
      }
    }

    OnDestroy {
      self.core.queue.sync {
        self.core.onPathChange = nil
        self.pollTimer?.cancel()
        self.pollTimer = nil
      }
    }

    OnStartObserving(statusEventName) {
      self.core.queue.async {
        self.hasListeners = true
        self.updatePollingOnQueue()
      }
    }

    OnStopObserving(statusEventName) {
      self.core.queue.async {
        self.hasListeners = false
        self.updatePollingOnQueue()
      }
    }

    /// Validates a TOML config with `parse_config` without starting anything.
    AsyncFunction("validateConfig") { (toml: String, redactions: [String]) in
      try self.ensureLinked()
      self.core.redactions = redactions.filter { !$0.isEmpty }
      do {
        try self.core.validate(toml: toml)
      } catch let error as EasyTierCoreError {
        throw Exception(name: "EasyTierInvalidConfig", description: error.message, code: "ERR_EASYTIER_CONFIG")
      }
    }
    .runOnQueue(core.queue)

    /// Starts the single EasyTier instance; a running one with the same config is kept.
    AsyncFunction("start") { (toml: String, instanceName: String, pollIntervalMs: Int, redactions: [String]) -> [String: Any] in
      try self.ensureLinked()
      self.core.redactions = redactions.filter { !$0.isEmpty }
      self.pollIntervalMs = max(pollIntervalMs, minPollIntervalMs)
      let kept: Bool
      do {
        kept = try self.core.startOnQueue(toml: toml, instanceName: instanceName)
      } catch let error as EasyTierCoreError {
        throw Exception(name: "EasyTierStartFailed", description: error.message, code: "ERR_EASYTIER_START")
      }
      self.updatePollingOnQueue()
      self.emitStatusOnQueue()
      return ["kept": kept]
    }
    .runOnQueue(core.queue)

    /// Stops every EasyTier instance (`retain_network_instance` with length 0).
    AsyncFunction("stop") {
      try self.ensureLinked()
      if let error = self.core.stopAllOnQueue() {
        throw Exception(name: "EasyTierStopFailed", description: error, code: "ERR_EASYTIER_STOP")
      }
      self.updatePollingOnQueue()
      self.emitStatusOnQueue()
    }
    .runOnQueue(core.queue)

    /// Restarts the running config (`start` with the same config keeps the instance instead).
    AsyncFunction("restart") {
      try self.ensureLinked()
      do {
        try self.core.restartOnQueue()
      } catch let error as EasyTierCoreError {
        throw Exception(name: "EasyTierStartFailed", description: error.message, code: "ERR_EASYTIER_START")
      }
      self.updatePollingOnQueue()
      self.emitStatusOnQueue()
    }
    .runOnQueue(core.queue)

    /// The config the app starts with at launch, before JS (nil = none).
    AsyncFunction("setLaunchConfig") { (toml: String?, instanceName: String?) in
      self.core.setLaunchConfig(toml: toml, instanceName: instanceName)
    }
    .runOnQueue(core.queue)

    /// Returns `{ instanceName?, running, infoJson?, error? }`; `infoJson` is the raw
    /// `NetworkInstanceRunningInfo` JSON, parsed on the JS side.
    AsyncFunction("getStatus") { () -> [String: Any] in
      return self.core.collectStatusOnQueue().compactMapValues { $0 }
    }
    .runOnQueue(core.queue)
  }

  // MARK: - Polling (core.queue only)

  private func updatePollingOnQueue() {
    let shouldPoll = EasyTierCore.isFrameworkLinked && hasListeners && core.instanceName != nil

    if let timer = pollTimer, !shouldPoll {
      timer.cancel()
      pollTimer = nil
    } else if shouldPoll {
      pollTimer?.cancel()
      let timer = DispatchSource.makeTimerSource(queue: core.queue)
      let interval = DispatchTimeInterval.milliseconds(pollIntervalMs)
      timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(100))
      timer.setEventHandler { [weak self] in
        self?.emitStatusOnQueue()
      }
      timer.resume()
      pollTimer = timer
    }
  }

  private func emitStatusOnQueue() {
    guard hasListeners else {
      return
    }
    sendEvent(statusEventName, core.collectStatusOnQueue())
  }

  private func ensureLinked() throws {
    if !EasyTierCore.isFrameworkLinked {
      throw Exception(
        name: "EasyTierUnavailable",
        description: "EasyTierFFI.xcframework is not linked into this build. Run modules/easytier/scripts/fetch-xcframework.js, then rebuild the app.",
        code: "ERR_EASYTIER_UNAVAILABLE"
      )
    }
  }
}
