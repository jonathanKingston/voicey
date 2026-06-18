import Foundation

/// Bounded RMS normalization for ASR inference (quiet speech boost; near-silence → empty).
///
/// Matches Granite benchmark behavior; used on the Qwen hot path before decode.
public enum InferenceAudioConditioning {
  public static let lowAudioRMSFloor: Float = 0.0008
  public static let lowAudioBoostThresholdRMS: Float = 0.012
  public static let targetInputRMS: Float = 0.03
  public static let maxInputGain: Float = 4.0

  public struct Result: Equatable {
    public let samples: [Float]
    public let inputRMS: Float
    public let appliedGain: Float

    public init(samples: [Float], inputRMS: Float, appliedGain: Float) {
      self.samples = samples
      self.inputRMS = inputRMS
      self.appliedGain = appliedGain
    }

    public var isBelowInferenceFloor: Bool {
      samples.isEmpty && inputRMS <= lowAudioRMSFloor
    }
  }

  public static func conditionForInference(_ samples: [Float]) -> Result {
    let rms = calculateRMS(samples)
    guard rms > lowAudioRMSFloor else {
      return Result(samples: [], inputRMS: rms, appliedGain: 1)
    }

    guard rms < lowAudioBoostThresholdRMS else {
      return Result(samples: samples, inputRMS: rms, appliedGain: 1)
    }

    let gain = min(targetInputRMS / max(rms, Float.leastNonzeroMagnitude), maxInputGain)
    let boosted = samples.map { min(max($0 * gain, -1), 1) }
    return Result(samples: boosted, inputRMS: rms, appliedGain: gain)
  }

  public static func calculateRMS(_ samples: [Float]) -> Float {
    guard !samples.isEmpty else { return 0 }
    var sumSquares: Float = 0
    for sample in samples {
      sumSquares += sample * sample
    }
    return sqrt(sumSquares / Float(samples.count))
  }
}
