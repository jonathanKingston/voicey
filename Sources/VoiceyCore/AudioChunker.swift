import Foundation

public struct AudioChunk: Equatable, Sendable {
  public let samples: [Float]
  public let startSample: Int
  public let sampleRate: Double

  public var startTime: TimeInterval {
    Double(startSample) / sampleRate
  }

  public var duration: TimeInterval {
    Double(samples.count) / sampleRate
  }

  public init(samples: [Float], startSample: Int, sampleRate: Double) {
    self.samples = samples
    self.startSample = startSample
    self.sampleRate = sampleRate
  }
}

public enum AudioChunker {
  public static func chunks(
    from samples: [Float],
    maxDuration: TimeInterval,
    sampleRate: Double
  ) -> [AudioChunk] {
    precondition(maxDuration > 0, "maxDuration must be greater than zero")
    precondition(sampleRate > 0, "sampleRate must be greater than zero")

    guard !samples.isEmpty else { return [] }

    let maxSamplesPerChunk = Int((maxDuration * sampleRate).rounded(.down))
    precondition(
      maxSamplesPerChunk > 0, "maxDuration and sampleRate must allow at least one sample")

    var chunks: [AudioChunk] = []
    chunks.reserveCapacity(Int(ceil(Double(samples.count) / Double(maxSamplesPerChunk))))

    var start = 0
    while start < samples.count {
      let end = min(start + maxSamplesPerChunk, samples.count)
      chunks.append(
        AudioChunk(
          samples: Array(samples[start..<end]),
          startSample: start,
          sampleRate: sampleRate
        ))
      start = end
    }

    return chunks
  }
}
