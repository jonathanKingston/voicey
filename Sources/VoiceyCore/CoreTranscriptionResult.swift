import Foundation

public struct CoreTranscriptionResult: Equatable, Sendable {
  public let text: String
  public let segments: [CoreTranscriptionSegment]

  public init(
    text: String,
    segments: [CoreTranscriptionSegment] = []
  ) {
    self.text = text
    self.segments = segments
  }
}

public struct CoreTranscriptionSegment: Equatable, Sendable {
  public let text: String
  public let startTime: TimeInterval
  public let endTime: TimeInterval

  public init(
    text: String,
    startTime: TimeInterval,
    endTime: TimeInterval
  ) {
    self.text = text
    self.startTime = startTime
    self.endTime = endTime
  }
}
