import Foundation

enum BenchmarkIncrementalTranscription {
  static func transcribe(
    samples: [Float],
    configuration: IncrementalTranscriptionConfiguration = .default,
    applyTrailingTrimHeuristic: Bool,
    transcribeChunk: @escaping ([Float]) async throws -> TranscriptionResult
  ) async throws -> TranscriptionResult {
    let coordinator = IncrementalTranscriptionCoordinator(
      configuration: configuration,
      transcribe: transcribeChunk,
      onUpdate: { _ in }
    )
    let frameSampleCount = max(
      1,
      Int(configuration.trailingTrimWindowDuration * configuration.sampleRate)
    )

    var startIndex = 0
    while startIndex < samples.count {
      let endIndex = min(startIndex + frameSampleCount, samples.count)
      coordinator.append(samples: Array(samples[startIndex..<endIndex]))
      startIndex = endIndex
    }

    return try await coordinator.flushAndFinish(
      applyTrailingTrimHeuristic: applyTrailingTrimHeuristic)
  }
}
