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
  func transcribe(samples: [Float]) async throws -> TranscriptionResult
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
  var state: TranscriptionSessionState { get async }
  func startRecording(requestID: String) async throws
  func stopRecording() async throws
  func cancel() async
}

public enum TranscriptionSessionEvent: Equatable, Sendable {
  case startRecording(startedAt: Date)
  case startProcessing(requestID: String)
  case complete(text: String, metadata: TranscriptionSessionMetadata)
  case fail(message: String)
  case cancel
}

public enum TranscriptionSessionTransitionError: LocalizedError {
  case invalidTransition(from: TranscriptionSessionState, event: TranscriptionSessionEvent)
  case emptyCompletedText
  case emptyFailureMessage
  case emptyRequestIdentifier

  public var errorDescription: String? {
    switch self {
    case .invalidTransition(let from, let event):
      return "Invalid transcription transition from \(from) with event \(event)."
    case .emptyCompletedText:
      return "Completed transcription text cannot be empty."
    case .emptyFailureMessage:
      return "Failure message cannot be empty."
    case .emptyRequestIdentifier:
      return "Request identifier cannot be empty."
    }
  }
}

public enum TranscriptionSessionReducer {
  public static func reduce(
    _ current: TranscriptionSessionState,
    event: TranscriptionSessionEvent
  ) throws -> TranscriptionSessionState {
    switch (current, event) {
    case (_, .cancel):
      return .idle

    case (.idle, .startRecording(let startedAt)),
      (.completed, .startRecording(let startedAt)),
      (.failed, .startRecording(let startedAt)):
      return .recording(startedAt: startedAt)

    case (.recording, .startProcessing(let requestID)):
      guard requestID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
        throw TranscriptionSessionTransitionError.emptyRequestIdentifier
      }
      return .processing(requestID: requestID)

    case (.processing, .complete(let text, let metadata)):
      guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
        throw TranscriptionSessionTransitionError.emptyCompletedText
      }
      return .completed(text: text, metadata: metadata)

    case (.processing, .fail(let message)):
      guard message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
        throw TranscriptionSessionTransitionError.emptyFailureMessage
      }
      return .failed(message: message)

    default:
      throw TranscriptionSessionTransitionError.invalidTransition(from: current, event: event)
    }
  }
}
