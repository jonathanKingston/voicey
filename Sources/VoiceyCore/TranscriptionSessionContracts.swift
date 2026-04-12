import Foundation

public struct TranscriptionSessionMetadata: Equatable, Sendable {
  public let language: String
  public let modelIdentifier: String
  public let processingTime: TimeInterval

  public init(
    language: String = "auto",
    modelIdentifier: String = "unknown",
    processingTime: TimeInterval = 0
  ) {
    self.language = language
    self.modelIdentifier = modelIdentifier
    self.processingTime = processingTime
  }
}

public enum TranscriptionSessionState: Equatable, Sendable {
  case idle
  case recording(startedAt: Date)
  case processing(requestID: String)
  case completed(text: String, metadata: TranscriptionSessionMetadata)
  case failed(message: String)

  public var isActive: Bool {
    switch self {
    case .recording, .processing:
      return true
    case .idle, .completed, .failed:
      return false
    }
  }
}

public protocol SpeechEngine: Sendable {
  func preload(modelIdentifier: String) async throws
  func transcribe(samples: [Float]) async throws -> DictationResult
  var isReady: Bool { get }
}

public protocol AudioCapturing: Sendable {
  func start() throws
  func stop() throws -> [Float]
}

public protocol TextDelivering: Sendable {
  func deliver(text: String) async throws
}

public protocol TranscriptionCoordinating: Sendable {
  var state: TranscriptionSessionState { get }
  func startRecording(requestID: String) async throws
  func stopRecording() async throws
  func cancel() async
}
