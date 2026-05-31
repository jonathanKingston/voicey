import Foundation

/// Benchmark CLI paths require bundled Rust workers — no Swift duplicate fallbacks.
enum BenchmarkRustRequirements {
  enum MissingComponent: LocalizedError {
    case supervisor
    case fetch
    case capture
    case text
    case inferWorker

    var errorDescription: String? {
      switch self {
      case .supervisor:
        return "voicey-supervisor not found (run make build-rust)"
      case .fetch:
        return "voicey-fetch not found (run make build-rust)"
      case .capture:
        return "voicey-capture not found (run make build-rust)"
      case .text:
        return "voicey-text not found (run make build-rust)"
      case .inferWorker:
        return "Voicey infer-worker entry point not available"
      }
    }
  }

  static func requireSupervisor() throws {
    guard VoiceyRuntimeConfiguration.rustSupervisorPath != nil else {
      throw MissingComponent.supervisor
    }
  }

  static func requireFetch() throws {
    guard VoiceyRuntimeConfiguration.fetchWorkerPath != nil else {
      throw MissingComponent.fetch
    }
  }

  static func requireCapture() throws {
    guard VoiceyRuntimeConfiguration.captureWorkerPath != nil else {
      throw MissingComponent.capture
    }
  }

  static func requireTextWorker() throws {
    guard VoiceyRuntimeConfiguration.textWorkerPath != nil else {
      throw MissingComponent.text
    }
  }

  static func requireInferWorker() throws {
    let path = VoiceyRuntimeConfiguration.voiceyExecutablePath()
    guard FileManager.default.isExecutableFile(atPath: path) else {
      throw MissingComponent.inferWorker
    }
  }

  /// Workers used by benchmark-transcribe (multiprocess Qwen + Rust post-process).
  static func requireTranscribeBenchmarkStack() throws {
    try requireSupervisor()
    try requireCapture()
    try requireInferWorker()
  }

  /// Full Rust stack including model download benchmarks.
  static func requireFullStack() throws {
    try requireTranscribeBenchmarkStack()
    try requireFetch()
    try requireTextWorker()
  }
}
