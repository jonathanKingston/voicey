import Foundation

enum TranscriptionRuntimeKind: String {
  case inProcess = "in-process"
  case multiprocess
}

enum TranscriptionRuntime {
  static func transcribe(
    samples: [Float],
    model: SpeechModel,
    runtime: TranscriptionRuntimeKind,
    warmupCount: Int
  ) async throws -> TranscriptionResult {
    SettingsManager.shared.selectedModel = model

    switch runtime {
    case .inProcess:
      return try await transcribeInProcess(samples: samples, model: model, warmupCount: warmupCount)
    case .multiprocess:
      return try await transcribeMultiprocess(samples: samples, model: model, warmupCount: warmupCount)
    }
  }

  private static func transcribeInProcess(
    samples: [Float],
    model: SpeechModel,
    warmupCount: Int
  ) async throws -> TranscriptionResult {
    switch model.backendKind {
    case .qwenMLX:
      let engine = QwenEngine()
      try await engine.loadModel(variant: model.rawValue)
      for _ in 0..<warmupCount {
        _ = try await engine.transcribe(audioBuffer: samples)
      }
      return try await engine.transcribe(audioBuffer: samples)
    case .whisperKit:
      let engine = WhisperEngine()
      try await engine.loadModel(variant: model.rawValue)
      for _ in 0..<warmupCount {
        _ = try await engine.transcribe(audioBuffer: samples)
      }
      return try await engine.transcribe(audioBuffer: samples)
    case .granitePython:
      let engine = GraniteEngine()
      try await engine.loadModel(variant: model.rawValue)
      for _ in 0..<warmupCount {
        _ = try await engine.transcribe(audioBuffer: samples)
      }
      return try await engine.transcribe(audioBuffer: samples)
    }
  }

  private static func transcribeMultiprocess(
    samples: [Float],
    model: SpeechModel,
    warmupCount: Int
  ) async throws -> TranscriptionResult {
    let supervisor = VoiceyRuntimeSupervisor.shared
    try await supervisor.prewarmInfer(model: model)
    for _ in 0..<warmupCount {
      _ = try await supervisor.transcribe(samples: samples, model: model, warmupAlreadyDone: true)
    }
    return try await supervisor.transcribe(samples: samples, model: model, warmupAlreadyDone: true)
  }
}
