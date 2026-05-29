import Foundation

struct IncrementalTranscriptionConfiguration {
  let sampleRate: Double
  let pauseDuration: TimeInterval
  let safetyTailDuration: TimeInterval
  let minimumChunkDuration: TimeInterval
  let speechRMSThreshold: Float
  let trailingTrimDuration: TimeInterval
  let trailingTrimWindowDuration: TimeInterval
  let trailingTrimHopDuration: TimeInterval
  let minimumTrailingTrimDuration: TimeInterval

  static let `default` = IncrementalTranscriptionConfiguration(
    sampleRate: 16_000,
    pauseDuration: 1.0,
    safetyTailDuration: 0.25,
    minimumChunkDuration: 0.5,
    speechRMSThreshold: 0.01,
    trailingTrimDuration: 0.5,
    trailingTrimWindowDuration: 0.02,
    trailingTrimHopDuration: 0.01,
    minimumTrailingTrimDuration: 0.08
  )

  var pauseSampleCount: Int {
    Int(pauseDuration * sampleRate)
  }

  var safetyTailSampleCount: Int {
    Int(safetyTailDuration * sampleRate)
  }

  var minimumChunkSampleCount: Int {
    Int(minimumChunkDuration * sampleRate)
  }

  var trailingTrimSampleCount: Int {
    Int(trailingTrimDuration * sampleRate)
  }

  var trailingTrimWindowSampleCount: Int {
    max(1, Int(trailingTrimWindowDuration * sampleRate))
  }

  var trailingTrimHopSampleCount: Int {
    max(1, Int(trailingTrimHopDuration * sampleRate))
  }

  var minimumTrailingTrimSampleCount: Int {
    Int(minimumTrailingTrimDuration * sampleRate)
  }

  func overriding(
    pauseDuration: TimeInterval? = nil,
    safetyTailDuration: TimeInterval? = nil,
    minimumChunkDuration: TimeInterval? = nil,
    speechRMSThreshold: Float? = nil
  ) -> IncrementalTranscriptionConfiguration {
    IncrementalTranscriptionConfiguration(
      sampleRate: sampleRate,
      pauseDuration: pauseDuration ?? self.pauseDuration,
      safetyTailDuration: safetyTailDuration ?? self.safetyTailDuration,
      minimumChunkDuration: minimumChunkDuration ?? self.minimumChunkDuration,
      speechRMSThreshold: speechRMSThreshold ?? self.speechRMSThreshold,
      trailingTrimDuration: trailingTrimDuration,
      trailingTrimWindowDuration: trailingTrimWindowDuration,
      trailingTrimHopDuration: trailingTrimHopDuration,
      minimumTrailingTrimDuration: minimumTrailingTrimDuration
    )
  }
}
