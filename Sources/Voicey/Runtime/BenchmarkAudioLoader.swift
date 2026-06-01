import Foundation

/// Loads benchmark audio via Rust workers when possible (#70 Phase 3).
enum BenchmarkAudioLoader {
  static func loadCapturedAudio(
    from url: URL,
    model: SpeechModel,
    runtime: TranscriptionRuntimeKind
  ) async throws -> CapturedAudio {
    switch runtime {
    case .multiprocess where model.isQwenModel:
      try BenchmarkRustRequirements.requireCapture()
      let handle = try await VoiceyCaptureWorkerSession.shared.loadWavFile(path: url.path)
      return .sharedBuffer(handle)
    case .inProcess, .multiprocess:
      let samples = try AudioFileSamples.load16kMonoFloatSamples(from: url)
      return .inMemory(samples)
    }
  }
}
