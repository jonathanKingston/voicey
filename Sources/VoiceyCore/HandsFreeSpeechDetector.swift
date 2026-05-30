import Foundation

public struct HandsFreeRecordingConfiguration: Sendable, Equatable {
  public static let `default` = HandsFreeRecordingConfiguration()

  public let sampleRate: Int
  public let preRollDuration: TimeInterval
  /// Legacy absolute floor; effective start uses `max(this, noiseFloor + speechStartMarginAboveNoise)`.
  public let speechStartThreshold: Float
  /// Legacy absolute ceiling for silence; effective end uses adaptive thresholds instead.
  public let speechEndThreshold: Float
  public let minimumSpeechDuration: TimeInterval
  public let silenceHangoverDuration: TimeInterval
  public let waitTimeoutDuration: TimeInterval
  /// Silence after the last utterance before an armed deferred-commit session auto-commits.
  /// Much longer than `silenceHangoverDuration` so mid-sentence thinking pauses never commit.
  public let autoCommitSilenceDuration: TimeInterval
  /// Level must exceed calibrated noise by at least this much to begin speech.
  public let speechStartMarginAboveNoise: Float
  /// Silence hangover ends when level stays below noise floor plus this margin.
  public let speechEndMarginAboveNoise: Float
  /// Also treat levels below this fraction of peak recording level as silence.
  public let speechEndPeakFraction: Float
  public let noiseFloorSmoothingFactor: Float
  public let initialNoiseFloor: Float
  /// Ignore speech-start detection until the mic level has been observed for this long.
  public let minimumCalibrationDuration: TimeInterval

  public init(
    sampleRate: Int = 16_000,
    preRollDuration: TimeInterval = 0.25,
    speechStartThreshold: Float = 0.09,
    speechEndThreshold: Float = 0.045,
    minimumSpeechDuration: TimeInterval = 0.18,
    silenceHangoverDuration: TimeInterval = 1.5,
    waitTimeoutDuration: TimeInterval = 8.0,
    autoCommitSilenceDuration: TimeInterval = 6.0,
    speechStartMarginAboveNoise: Float = 0.07,
    speechEndMarginAboveNoise: Float = 0.025,
    speechEndPeakFraction: Float = 0.30,
    noiseFloorSmoothingFactor: Float = 0.2,
    initialNoiseFloor: Float = 0.02,
    minimumCalibrationDuration: TimeInterval = 0.35
  ) {
    self.sampleRate = sampleRate
    self.preRollDuration = preRollDuration
    self.speechStartThreshold = speechStartThreshold
    self.speechEndThreshold = speechEndThreshold
    self.minimumSpeechDuration = minimumSpeechDuration
    self.silenceHangoverDuration = silenceHangoverDuration
    self.waitTimeoutDuration = waitTimeoutDuration
    self.autoCommitSilenceDuration = autoCommitSilenceDuration
    self.speechStartMarginAboveNoise = speechStartMarginAboveNoise
    self.speechEndMarginAboveNoise = speechEndMarginAboveNoise
    self.speechEndPeakFraction = speechEndPeakFraction
    self.noiseFloorSmoothingFactor = noiseFloorSmoothingFactor
    self.initialNoiseFloor = initialNoiseFloor
    self.minimumCalibrationDuration = minimumCalibrationDuration
  }

  public var preRollSamples: Int {
    max(0, Int((preRollDuration * Double(sampleRate)).rounded()))
  }

  public var minimumSpeechSamples: Int {
    max(1, Int((minimumSpeechDuration * Double(sampleRate)).rounded()))
  }

  public var silenceHangoverSamples: Int {
    max(1, Int((silenceHangoverDuration * Double(sampleRate)).rounded()))
  }

  public var waitTimeoutSamples: Int {
    max(1, Int((waitTimeoutDuration * Double(sampleRate)).rounded()))
  }

  public var minimumCalibrationSamples: Int {
    max(1, Int((minimumCalibrationDuration * Double(sampleRate)).rounded()))
  }
}

public struct HandsFreeSpeechDetector: Sendable, Equatable {
  public enum Phase: Sendable, Equatable {
    case waitingForSpeech
    case recording
    case speechEnded
  }

  public enum Event: Sendable, Equatable {
    case speechStarted(startSampleIndex: Int)
    case speechEnded(endSampleIndex: Int)
  }

  public let configuration: HandsFreeRecordingConfiguration
  public private(set) var phase: Phase = .waitingForSpeech
  public private(set) var speechStartSampleIndex: Int?
  public private(set) var speechEndSampleIndex: Int?

  private var lastObservedSampleCount: Int = 0
  private var consecutiveSpeechSamples: Int = 0
  private var consecutiveSilenceSamples: Int = 0
  private var lastSpeechSampleIndex: Int = 0
  private var noiseFloor: Float
  private var peakLevelWhileRecording: Float = 0
  private var samplesObservedWhileWaiting: Int = 0
  /// Speech onset captured during the initial calibration window (first utterance pre-roll).
  private var preCalibrationSpeechCandidateSampleIndex: Int?

  public init(configuration: HandsFreeRecordingConfiguration = .default) {
    self.configuration = configuration
    self.noiseFloor = configuration.initialNoiseFloor
  }

  public var hasDetectedSpeech: Bool {
    speechStartSampleIndex != nil
  }

  public mutating func consume(level: Float, totalSamplesCaptured: Int) -> [Event] {
    let normalizedTotalSamples = max(totalSamplesCaptured, 0)
    if normalizedTotalSamples < lastObservedSampleCount {
      lastObservedSampleCount = normalizedTotalSamples
    }

    if phase == .speechEnded {
      reopenListeningAfterUtterance()
    }

    let sampleDelta = max(normalizedTotalSamples - lastObservedSampleCount, 0)
    lastObservedSampleCount = normalizedTotalSamples

    guard sampleDelta > 0 else { return [] }

    switch phase {
    case .waitingForSpeech:
      adaptNoiseFloor(toward: level)
      samplesObservedWhileWaiting += sampleDelta
      let startThreshold = effectiveStartThreshold()
      notePreCalibrationSpeechCandidateIfNeeded(
        level: level,
        startThreshold: startThreshold,
        normalizedTotalSamples: normalizedTotalSamples,
        sampleDelta: sampleDelta
      )

      guard samplesObservedWhileWaiting >= configuration.minimumCalibrationSamples else {
        consecutiveSpeechSamples = 0
        return []
      }

      if consecutiveSpeechSamples == 0, level < startThreshold {
        preCalibrationSpeechCandidateSampleIndex = nil
      }

      guard level >= startThreshold else {
        consecutiveSpeechSamples = 0
        return []
      }

      consecutiveSpeechSamples += sampleDelta
      if consecutiveSpeechSamples < configuration.minimumSpeechSamples {
        return []
      }

      let speechStartIndex = resolvedSpeechStartSampleIndex(
        normalizedTotalSamples: normalizedTotalSamples,
        consecutiveSpeechSamples: consecutiveSpeechSamples
      )
      speechStartSampleIndex = speechStartIndex
      lastSpeechSampleIndex = normalizedTotalSamples
      consecutiveSilenceSamples = 0
      peakLevelWhileRecording = level
      phase = .recording
      return [.speechStarted(startSampleIndex: speechStartIndex)]

    case .recording:
      peakLevelWhileRecording = max(peakLevelWhileRecording, level)
      let endThreshold = effectiveEndThreshold()

      if level >= endThreshold {
        lastSpeechSampleIndex = normalizedTotalSamples
        consecutiveSilenceSamples = 0
        return []
      }

      consecutiveSilenceSamples += sampleDelta
      guard consecutiveSilenceSamples >= configuration.silenceHangoverSamples else {
        return []
      }

      let speechEndIndex = max(lastSpeechSampleIndex, speechStartSampleIndex ?? 0)
      speechEndSampleIndex = speechEndIndex
      phase = .speechEnded
      return [.speechEnded(endSampleIndex: speechEndIndex)]

    case .speechEnded:
      return []
    }
  }

  public func boundedSamples(from samples: [Float]) -> [Float] {
    guard let slice = boundedSlice(in: samples.count) else { return [] }
    return Array(samples[slice.offset..<(slice.offset + slice.count)])
  }

  /// Sample range within a capture buffer for hands-free mode (no PCM load required).
  public func boundedSlice(in totalSampleCount: Int) -> (offset: Int, count: Int)? {
    guard let speechStartSampleIndex else { return nil }
    let startIndex = min(max(speechStartSampleIndex, 0), totalSampleCount)
    let endIndex = min(max(speechEndSampleIndex ?? totalSampleCount, startIndex), totalSampleCount)
    let count = endIndex - startIndex
    guard count > 0 else { return nil }
    return (startIndex, count)
  }

  /// Resets VAD after an utterance while keeping the learned noise floor for the session.
  public mutating func prepareForNextUtterance(sampleBaseline: Int) {
    reopenListeningAfterUtterance()
    lastObservedSampleCount = max(sampleBaseline, 0)
  }

  /// Clears utterance bounds but keeps sample timing so the next poll can advance.
  public mutating func reopenListeningAfterUtterance() {
    phase = .waitingForSpeech
    speechStartSampleIndex = nil
    speechEndSampleIndex = nil
    consecutiveSpeechSamples = 0
    consecutiveSilenceSamples = 0
    peakLevelWhileRecording = 0
    preCalibrationSpeechCandidateSampleIndex = nil
  }

  /// Closes an in-progress utterance when the user ends the session mid-phrase.
  public mutating func forceEndUtterance(at endSampleIndex: Int) {
    guard speechStartSampleIndex != nil else { return }
    let normalizedEnd = max(endSampleIndex, speechStartSampleIndex ?? 0)
    speechEndSampleIndex = normalizedEnd
    lastSpeechSampleIndex = max(lastSpeechSampleIndex, normalizedEnd)
    phase = .speechEnded
  }

  private mutating func adaptNoiseFloor(toward level: Float) {
    let startThreshold = effectiveStartThreshold()
    let ambientAdaptCeiling =
      configuration.speechStartThreshold + configuration.speechStartMarginAboveNoise
    // Track sustained ambient noise, but do not chase loud speech levels (clips first words).
    guard level <= startThreshold || level < ambientAdaptCeiling else { return }
    let smoothing = configuration.noiseFloorSmoothingFactor
    noiseFloor += smoothing * (level - noiseFloor)
  }

  private mutating func notePreCalibrationSpeechCandidateIfNeeded(
    level: Float,
    startThreshold: Float,
    normalizedTotalSamples: Int,
    sampleDelta: Int
  ) {
    guard samplesObservedWhileWaiting < configuration.minimumCalibrationSamples else { return }
    let softThreshold = noiseFloor + configuration.speechStartMarginAboveNoise * 0.45
    guard level >= softThreshold || level >= startThreshold else { return }
    let chunkStart = max(0, normalizedTotalSamples - sampleDelta)
    if let existing = preCalibrationSpeechCandidateSampleIndex {
      preCalibrationSpeechCandidateSampleIndex = min(existing, chunkStart)
    } else {
      preCalibrationSpeechCandidateSampleIndex = chunkStart
    }
  }

  private func resolvedSpeechStartSampleIndex(
    normalizedTotalSamples: Int,
    consecutiveSpeechSamples: Int
  ) -> Int {
    let thresholdBasedStart = max(
      0,
      normalizedTotalSamples - consecutiveSpeechSamples - configuration.preRollSamples
    )
    guard let candidateStart = preCalibrationSpeechCandidateSampleIndex else {
      return thresholdBasedStart
    }
    let candidateWithPreRoll = max(0, candidateStart - configuration.preRollSamples)
    return min(thresholdBasedStart, candidateWithPreRoll)
  }

  private func effectiveStartThreshold() -> Float {
    max(
      configuration.speechStartThreshold,
      noiseFloor + configuration.speechStartMarginAboveNoise
    )
  }

  private func effectiveEndThreshold() -> Float {
    let floorBased = noiseFloor + configuration.speechEndMarginAboveNoise
    let peakBased = peakLevelWhileRecording * configuration.speechEndPeakFraction
    return max(floorBased, peakBased, configuration.speechEndThreshold)
  }
}
