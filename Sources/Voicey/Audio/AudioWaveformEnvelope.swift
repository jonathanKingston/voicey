import Accelerate
import Foundation

/// Downsamples captured PCM into normalized bar heights for the transcription overlay.
enum AudioWaveformEnvelope {
  /// Bar count sized to fit the overlay activity slot (~100pt wide).
  static let displayBarCount = 24

  /// Builds `barCount` heights in 0...1 from 16 kHz mono float samples.
  static func normalizedBars(from samples: [Float], barCount: Int = displayBarCount) -> [Float] {
    guard !samples.isEmpty, barCount > 0 else {
      return Array(repeating: 0.08, count: max(barCount, displayBarCount))
    }

    var rmsPerBar = [Float](repeating: 0, count: barCount)
    for index in 0..<barCount {
      let start = index * samples.count / barCount
      let end = (index + 1) * samples.count / barCount
      guard end > start else {
        rmsPerBar[index] = 0
        continue
      }
      rmsPerBar[index] = rms(in: samples, start: start, count: end - start)
    }

    return normalizeBarHeights(rmsPerBar, barCount: barCount)
  }

  /// Builds bar heights from a `voicey-capture` PCM file without loading the full utterance into memory.
  static func normalizedBars(fromSharedBuffer handle: PCMBufferHandle, barCount: Int = displayBarCount) throws
    -> [Float]
  {
    guard handle.sampleCount > 0, barCount > 0 else {
      return Array(repeating: 0.08, count: max(barCount, displayBarCount))
    }

    var rmsPerBar = [Float](repeating: 0, count: barCount)
    for index in 0..<barCount {
      let start = index * handle.sampleCount / barCount
      let end = (index + 1) * handle.sampleCount / barCount
      guard end > start else {
        rmsPerBar[index] = 0
        continue
      }
      let slice = try SharedMemoryPCM.read(
        name: handle.shmName,
        sampleCount: end - start,
        sampleOffset: handle.sampleOffset + start
      )
      rmsPerBar[index] = rms(in: slice, start: 0, count: slice.count)
    }

    return normalizeBarHeights(rmsPerBar, barCount: barCount)
  }

  private static func normalizeBarHeights(_ rmsPerBar: [Float], barCount: Int) -> [Float] {
    var peak: Float = 0.000_01
    vDSP_maxv(rmsPerBar, 1, &peak, vDSP_Length(barCount))

    return rmsPerBar.map { rms in
      let normalized = rms / peak
      return max(0.08, min(1.0, normalized * 0.92 + 0.08))
    }
  }

  /// Estimated decode progress from elapsed wall time and recent Qwen RTF.
  static func estimatedProcessingProgress(
    startedAt: Date,
    now: Date,
    audioDuration: TimeInterval,
    estimatedRTF: Double
  ) -> Double {
    guard audioDuration > 0, estimatedRTF > 0 else { return 0 }
    let expectedWallSeconds = audioDuration * estimatedRTF
    guard expectedWallSeconds > 0 else { return 0 }
    let elapsed = now.timeIntervalSince(startedAt)
    return min(0.92, max(0, elapsed / expectedWallSeconds))
  }

  private static func rms(in samples: [Float], start: Int, count: Int) -> Float {
    guard start >= 0, count > 0, start + count <= samples.count else { return 0 }
    var rms: Float = 0
    samples.withUnsafeBufferPointer { buffer in
      guard let base = buffer.baseAddress else { return }
      vDSP_rmsqv(base.advanced(by: start), 1, &rms, vDSP_Length(count))
    }
    return rms
  }
}
