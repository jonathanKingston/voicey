import Foundation

enum VoiceyRuntimeConfiguration {
  private static let runtimeEnvironmentKey = "VOICEY_RUNTIME"
  private static let disableRustWorkersKey = "VOICEY_DISABLE_RUST_WORKERS"
  private static let useRustSupervisorKey = "VOICEY_USE_RUST_SUPERVISOR"
  private static let useRustFetchKey = "VOICEY_USE_RUST_FETCH"
  private static let useRustCaptureKey = "VOICEY_USE_RUST_CAPTURE"
  private static let useFetchSandboxKey = "VOICEY_USE_FETCH_SANDBOX"
  private static let useRustTextKey = "VOICEY_USE_RUST_TEXT"
  private static let useXPCServicesKey = "VOICEY_USE_XPC"
  private static let fetchSandboxProfileKey = "VOICEY_FETCH_SANDBOX_PROFILE"

  private static var rustWorkersDisabled: Bool {
    ProcessInfo.processInfo.environment[disableRustWorkersKey] == "1"
  }

  /// Whether Qwen transcription runs in a separate `Voicey infer-worker` process.
  static func usesInferWorker(for model: SpeechModel) -> Bool {
    guard model.backendKind == .qwenMLX else { return false }
    if let raw = ProcessInfo.processInfo.environment[runtimeEnvironmentKey]?.lowercased() {
      switch raw {
      case "in-process", "inprocess", "in_process":
        return false
      case "multiprocess", "multi-process", "multi_process":
        return true
      default:
        break
      }
    }
    return true
  }

  static var mode: VoiceyRuntimeMode {
    usesInferWorker(for: SettingsManager.shared.selectedModel) ? .multiprocess : .inProcess
  }

  /// Default on when `voicey-supervisor` is present in the app bundle or `.build/debug`.
  static var useRustSupervisor: Bool {
    if rustWorkersDisabled { return false }
    if ProcessInfo.processInfo.environment[useRustSupervisorKey] == "0" { return false }
    if ProcessInfo.processInfo.environment[useRustSupervisorKey] == "1" { return true }
    return rustSupervisorPath != nil
  }

  /// Default on when `voicey-fetch` is present — Qwen downloads use the fetch worker.
  static var useRustFetch: Bool {
    if rustWorkersDisabled { return false }
    if ProcessInfo.processInfo.environment[useRustFetchKey] == "0" { return false }
    if ProcessInfo.processInfo.environment[useRustFetchKey] == "1" { return true }
    return fetchWorkerPath != nil
  }

  /// Default on when `voicey-capture` is present — hotkey recording uses the capture worker.
  static var useRustCaptureHotPath: Bool {
    if rustWorkersDisabled { return false }
    if ProcessInfo.processInfo.environment[useRustCaptureKey] == "0" { return false }
    if ProcessInfo.processInfo.environment[useRustCaptureKey] == "1" { return true }
    return captureWorkerPath != nil
  }

  /// Default on when `voicey-text` is present — transcription post-processing uses the text worker.
  static var useRustTextPostProcess: Bool {
    if rustWorkersDisabled { return false }
    if ProcessInfo.processInfo.environment[useRustTextKey] == "0" { return false }
    if ProcessInfo.processInfo.environment[useRustTextKey] == "1" { return true }
    return textWorkerPath != nil
  }

  static func workerProcessEnvironment() -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    environment["VOICEY_INFER_WORKER"] = voiceyExecutablePath()
    if let capturePath = captureWorkerPath {
      environment["VOICEY_CAPTURE_WORKER"] = capturePath
    }
    if let fetchPath = fetchWorkerPath {
      environment["VOICEY_FETCH_WORKER"] = fetchPath
    }
    if let textPath = textWorkerPath {
      environment["VOICEY_TEXT_WORKER"] = textPath
    }
    return environment
  }

  static var useXPCServices: Bool {
    ProcessInfo.processInfo.environment[useXPCServicesKey] == "1"
  }

  static var fetchSandboxProfileOverride: String? {
    let value = ProcessInfo.processInfo.environment[fetchSandboxProfileKey]?.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    guard let value, !value.isEmpty else { return nil }
    return value
  }

  static var usesFetchSandboxByDefault: Bool {
    #if VOICEY_DIRECT_DISTRIBUTION
      if ProcessInfo.processInfo.environment[useFetchSandboxKey] == "0" { return false }
      return true
    #else
      return ProcessInfo.processInfo.environment[useFetchSandboxKey] == "1"
    #endif
  }

  static func voiceyExecutablePath() -> String {
    if let override = ProcessInfo.processInfo.environment["VOICEY_BINARY"], !override.isEmpty {
      return override
    }
    return Bundle.main.executablePath ?? CommandLine.arguments[0]
  }

  static func workerBinary(named name: String) -> String? {
    if let override = ProcessInfo.processInfo.environment["VOICEY_\(name.uppercased())"], !override.isEmpty {
      return override
    }
    let executableDirectory = URL(fileURLWithPath: voiceyExecutablePath())
      .deletingLastPathComponent()
    let candidate = executableDirectory.appendingPathComponent(name).path
    if FileManager.default.isExecutableFile(atPath: candidate) {
      return candidate
    }
    let buildCandidate = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent(".build/debug/\(name)").path
    if FileManager.default.isExecutableFile(atPath: buildCandidate) {
      return buildCandidate
    }
    let cargoCandidate = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("target/debug/\(name)").path
    if FileManager.default.isExecutableFile(atPath: cargoCandidate) {
      return cargoCandidate
    }
    return nil
  }

  static var inferWorkerPath: String {
    voiceyExecutablePath()
  }

  static var captureWorkerPath: String? {
    workerBinary(named: "voicey-capture")
  }

  static var fetchWorkerPath: String? {
    workerBinary(named: "voicey-fetch")
  }

  static var textWorkerPath: String? {
    workerBinary(named: "voicey-text")
  }

  static var rustSupervisorPath: String? {
    workerBinary(named: "voicey-supervisor")
  }
}

enum VoiceyRuntimeMode: String, Sendable {
  case inProcess
  case multiprocess
}
