import Foundation

enum VoiceyRuntimeMode: String, Sendable {
  case inProcess
  case multiprocess
}

enum VoiceyRuntimeConfiguration {
  private static let runtimeEnvironmentKey = "VOICEY_RUNTIME"
  private static let useRustSupervisorKey = "VOICEY_USE_RUST_SUPERVISOR"
  private static let useXPCServicesKey = "VOICEY_USE_XPC"

  /// Whether Qwen transcription runs in a separate `Voicey infer-worker` process.
  /// Default: on for Qwen models. Set `VOICEY_RUNTIME=in-process` to force in-app MLX (support / benchmarks).
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

  /// Legacy helper used by benchmarks (`TranscriptionRuntimeKind`).
  static var mode: VoiceyRuntimeMode {
    usesInferWorker(for: SettingsManager.shared.selectedModel) ? .multiprocess : .inProcess
  }

  static var useRustSupervisor: Bool {
    ProcessInfo.processInfo.environment[useRustSupervisorKey] == "1"
  }

  private static let useRustFetchKey = "VOICEY_USE_RUST_FETCH"
  private static let useRustCaptureKey = "VOICEY_USE_RUST_CAPTURE"

  /// When set, Qwen downloads preflight the Rust `voicey-fetch` worker (fail fast if missing).
  static var useRustFetch: Bool {
    ProcessInfo.processInfo.environment[useRustFetchKey] == "1"
  }

  /// When set, capture prewarm uses a long-lived `voicey-capture` worker when available.
  static var useRustCapture: Bool {
    ProcessInfo.processInfo.environment[useRustCaptureKey] == "1"
  }

  /// Environment variables for `voicey-supervisor` child worker spawning.
  static func workerProcessEnvironment() -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    environment["VOICEY_INFER_WORKER"] = voiceyExecutablePath()
    if let capturePath = captureWorkerPath {
      environment["VOICEY_CAPTURE_WORKER"] = capturePath
    }
    if let fetchPath = fetchWorkerPath {
      environment["VOICEY_FETCH_WORKER"] = fetchPath
    }
    return environment
  }

  static var useXPCServices: Bool {
    ProcessInfo.processInfo.environment[useXPCServicesKey] == "1"
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
    let executableDirectory = URL(fileURLWithPath: voiceyExecutablePath()).deletingLastPathComponent()
    let candidate = executableDirectory.appendingPathComponent(name).path
    if FileManager.default.isExecutableFile(atPath: candidate) {
      return candidate
    }
    let buildCandidate = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent(".build/debug/\(name)").path
    if FileManager.default.isExecutableFile(atPath: buildCandidate) {
      return buildCandidate
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

  static var rustSupervisorPath: String? {
    workerBinary(named: "voicey-supervisor")
  }
}
