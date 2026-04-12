import Foundation

public struct PerformanceMetrics: Equatable, Sendable {
  public let realTimeFactor: Double
  public let audioDuration: TimeInterval
  public let processingTime: TimeInterval
  public let thermalState: ProcessInfo.ThermalState

  public init(
    realTimeFactor: Double,
    audioDuration: TimeInterval,
    processingTime: TimeInterval,
    thermalState: ProcessInfo.ThermalState
  ) {
    self.realTimeFactor = realTimeFactor
    self.audioDuration = audioDuration
    self.processingTime = processingTime
    self.thermalState = thermalState
  }

  public var isStruggling: Bool {
    if realTimeFactor > 2.0 { return true }
    if thermalState == .critical { return true }
    if thermalState == .serious && realTimeFactor > 1.0 { return true }
    return false
  }

  public var description: String {
    let rtfStr = String(format: "%.2fx", realTimeFactor)
    let thermalStr: String
    switch thermalState {
    case .nominal: thermalStr = "nominal"
    case .fair: thermalStr = "fair"
    case .serious: thermalStr = "serious"
    case .critical: thermalStr = "critical"
    @unknown default: thermalStr = "unknown"
    }
    return "RTF: \(rtfStr), Thermal: \(thermalStr)"
  }

  public var suggestion: String? {
    if thermalState == .critical || thermalState == .serious {
      return
        "System is running hot. Consider using a smaller model or letting the device cool down."
    }
    if realTimeFactor > 2.0 {
      return
        "Transcription is slow. Consider switching to a faster model like 'Small' for better performance."
    }
    if realTimeFactor > 1.5 {
      return "Transcription may be slow on longer recordings. A smaller model might help."
    }
    return nil
  }
}

public struct TranscriptionToken: Equatable, Sendable {
  public let text: String
  public let probability: Float
  public let startTime: TimeInterval
  public let endTime: TimeInterval

  public init(
    text: String,
    probability: Float,
    startTime: TimeInterval,
    endTime: TimeInterval
  ) {
    self.text = text
    self.probability = probability
    self.startTime = startTime
    self.endTime = endTime
  }
}

public struct TranscriptionSegment: Equatable, Sendable {
  public let text: String
  public let startTime: TimeInterval
  public let endTime: TimeInterval
  public let tokens: [TranscriptionToken]

  public init(
    text: String,
    startTime: TimeInterval,
    endTime: TimeInterval,
    tokens: [TranscriptionToken] = []
  ) {
    self.text = text
    self.startTime = startTime
    self.endTime = endTime
    self.tokens = tokens
  }
}

public struct TranscriptionResult: Equatable, Sendable {
  public let text: String
  public let segments: [TranscriptionSegment]
  public let language: String
  public let processingTime: TimeInterval
  public let performanceMetrics: PerformanceMetrics

  public init(
    text: String,
    segments: [TranscriptionSegment],
    language: String,
    processingTime: TimeInterval,
    performanceMetrics: PerformanceMetrics
  ) {
    self.text = text
    self.segments = segments
    self.language = language
    self.processingTime = processingTime
    self.performanceMetrics = performanceMetrics
  }
}
