import Foundation

public struct HandsFreeRecordingConfiguration: Sendable, Equatable {
  public static let `default` = HandsFreeRecordingConfiguration()

  public let sampleRate: Int
  public let preRollDuration: TimeInterval
  public let speechStartThreshold: Float
  public let speechEndThreshold: Float
  public let minimumSpeechDuration: TimeInterval
  public let silenceHangoverDuration: TimeInterval
  public let waitTimeoutDuration: TimeInterval

  public init(
    sampleRate: Int = 16_000,
    preRollDuration: TimeInterval = 0.25,
    speechStartThreshold: Float = 0.09,
    speechEndThreshold: Float = 0.045,
    minimumSpeechDuration: TimeInterval = 0.18,
    silenceHangoverDuration: TimeInterval = 0.8,
    waitTimeoutDuration: TimeInterval = 8.0
  ) {
    self.sampleRate = sampleRate
    self.preRollDuration = preRollDuration
    self.speechStartThreshold = speechStartThreshold
    self.speechEndThreshold = speechEndThreshold
    self.minimumSpeechDuration = minimumSpeechDuration
    self.silenceHangoverDuration = silenceHangoverDuration
    self.waitTimeoutDuration = waitTimeoutDuration
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

  public init(configuration: HandsFreeRecordingConfiguration = .default) {
    self.configuration = configuration
  }

  public var hasDetectedSpeech: Bool {
    speechStartSampleIndex != nil
  }

  public mutating func consume(level: Float, totalSamplesCaptured: Int) -> [Event] {
    let normalizedTotalSamples = max(totalSamplesCaptured, 0)
    let sampleDelta = max(normalizedTotalSamples - lastObservedSampleCount, 0)
    lastObservedSampleCount = normalizedTotalSamples

    guard sampleDelta > 0 else { return [] }

    switch phase {
    case .waitingForSpeech:
      guard level >= configuration.speechStartThreshold else {
        consecutiveSpeechSamples = 0
        return []
      }

      consecutiveSpeechSamples += sampleDelta
      if consecutiveSpeechSamples < configuration.minimumSpeechSamples {
        return []
      }

      let speechStartIndex = max(
        0,
        normalizedTotalSamples - consecutiveSpeechSamples - configuration.preRollSamples
      )
      speechStartSampleIndex = speechStartIndex
      lastSpeechSampleIndex = normalizedTotalSamples
      consecutiveSilenceSamples = 0
      phase = .recording
      return [.speechStarted(startSampleIndex: speechStartIndex)]

    case .recording:
      if level >= configuration.speechEndThreshold {
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
    guard let speechStartSampleIndex else { return [] }
    let startIndex = min(max(speechStartSampleIndex, 0), samples.count)
    let endIndex = min(max(speechEndSampleIndex ?? samples.count, startIndex), samples.count)
    return Array(samples[startIndex..<endIndex])
  }
}
