import Foundation

extension IncrementalTranscriptionCoordinator {
  func trimTrailingLowEnergyAudio(_ samples: [Float]) -> [Float] {
    guard !samples.isEmpty else { return samples }

    let maxTrimSamples = configuration.trailingTrimSampleCount
    let windowSamples = configuration.trailingTrimWindowSampleCount
    let hopSamples = configuration.trailingTrimHopSampleCount
    let minTrimSamples = configuration.minimumTrailingTrimSampleCount

    guard samples.count > windowSamples else { return samples }
    let boundedMaxTrim = min(maxTrimSamples, samples.count - windowSamples)
    guard boundedMaxTrim >= minTrimSamples else { return samples }

    let scanStart = samples.count - boundedMaxTrim
    var scanIndex = samples.count - windowSamples
    var keepEndIndex = samples.count

    while scanIndex >= scanStart {
      let windowRMS = rms(in: samples, start: scanIndex, count: windowSamples)
      if windowRMS > configuration.speechRMSThreshold {
        keepEndIndex = scanIndex + windowSamples
        break
      }
      scanIndex -= hopSamples
    }

    let trimmedSampleCount = samples.count - keepEndIndex
    guard trimmedSampleCount >= minTrimSamples else { return samples }

    AppLogger.audio.info(
      "IncrementalTranscription: Trimmed \(trimmedSampleCount) trailing low-energy samples"
    )
    return Array(samples.prefix(keepEndIndex))
  }

  func rms(_ samples: [Float]) -> Float {
    guard !samples.isEmpty else { return 0 }

    let sumSquares = samples.reduce(Float(0)) { partialResult, sample in
      partialResult + sample * sample
    }
    return sqrt(sumSquares / Float(samples.count))
  }

  private func rms(in samples: [Float], start: Int, count: Int) -> Float {
    guard start >= 0, count > 0, start + count <= samples.count else { return 0 }

    let window = samples[start..<(start + count)]
    let sumSquares = window.reduce(Float(0)) { partialResult, sample in
      partialResult + sample * sample
    }
    return sqrt(sumSquares / Float(count))
  }
}
