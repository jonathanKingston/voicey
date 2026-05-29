import Foundation

enum TranscriptionRuntimeKind: String {
  case inProcess = "in-process"
  case multiprocess
}

enum TranscriptionRuntimeError: LocalizedError {
  case multiprocessRequiresQwen(SpeechModel)

  var errorDescription: String? {
    switch self {
    case .multiprocessRequiresQwen(let model):
      return
        "Multiprocess runtime only supports Qwen models; \(model.rawValue) requires --runtime in-process"
    }
  }
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
      return try await BenchmarkSpeechBackend.transcribe(
        samples: samples,
        model: model,
        warmupCount: warmupCount
      )
    case .multiprocess:
      return try await transcribeMultiprocess(
        samples: samples,
        model: model,
        warmupCount: warmupCount
      )
    }
  }

  private static func transcribeMultiprocess(
    samples: [Float],
    model: SpeechModel,
    warmupCount: Int
  ) async throws -> TranscriptionResult {
    guard model.isQwenModel else {
      throw TranscriptionRuntimeError.multiprocessRequiresQwen(model)
    }

    let supervisor = VoiceyRuntimeSupervisor.shared
    try await supervisor.prewarmInfer(model: model)
    for _ in 0..<warmupCount {
      _ = try await supervisor.transcribe(samples: samples, model: model, warmupAlreadyDone: true)
    }
    return try await supervisor.transcribe(samples: samples, model: model, warmupAlreadyDone: true)
  }
}
