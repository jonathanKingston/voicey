import Foundation

/// In-process Whisper, Granite, and Qwen engines for benchmark CLI tooling only.
///
/// Production transcription uses Qwen through `AppDelegate` and the Rust runtime workers.
/// Do not call this from app UI or hotkey paths.
enum BenchmarkSpeechBackend {
  final class LoadedEngine: @unchecked Sendable {
    private let model: SpeechModel
    private var whisperEngine: WhisperEngine?
    private var graniteEngine: GraniteEngine?
    private var qwenEngine: QwenEngine?

    fileprivate init(model: SpeechModel) {
      self.model = model
    }

    func transcribe(audioBuffer: [Float]) async throws -> TranscriptionResult {
      switch model.backendKind {
      case .whisperKit:
        guard let whisperEngine else {
          throw BenchmarkSpeechBackendError.engineNotLoaded
        }
        return try await whisperEngine.transcribe(audioBuffer: audioBuffer)
      case .granitePython:
        guard let graniteEngine else {
          throw BenchmarkSpeechBackendError.engineNotLoaded
        }
        return try await graniteEngine.transcribe(audioBuffer: audioBuffer)
      case .qwenMLX:
        guard let qwenEngine else {
          throw BenchmarkSpeechBackendError.engineNotLoaded
        }
        return try await qwenEngine.transcribe(audioBuffer: audioBuffer)
      }
    }
  }

  static func loadEngine(for model: SpeechModel) async throws -> LoadedEngine {
    let engine = LoadedEngine(model: model)
    switch model.backendKind {
    case .whisperKit:
      let whisperEngine = WhisperEngine()
      try await whisperEngine.loadModel(variant: model.rawValue)
      engine.whisperEngine = whisperEngine
    case .granitePython:
      let graniteEngine = GraniteEngine()
      try await graniteEngine.loadModel(variant: model.rawValue)
      engine.graniteEngine = graniteEngine
    case .qwenMLX:
      let qwenEngine = QwenEngine()
      try await qwenEngine.loadModel(variant: model.rawValue)
      engine.qwenEngine = qwenEngine
    }
    return engine
  }

  static func transcribe(
    samples: [Float],
    model: SpeechModel,
    warmupCount: Int = 0
  ) async throws -> TranscriptionResult {
    let engine = try await loadEngine(for: model)
    for _ in 0..<warmupCount {
      _ = try await engine.transcribe(audioBuffer: samples)
    }
    return try await engine.transcribe(audioBuffer: samples)
  }
}

enum BenchmarkSpeechBackendError: LocalizedError {
  case engineNotLoaded

  var errorDescription: String? {
    switch self {
    case .engineNotLoaded:
      return "Benchmark engine was not loaded"
    }
  }
}
