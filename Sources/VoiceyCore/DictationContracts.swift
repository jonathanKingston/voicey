import Foundation

public enum DictationRequestStatus: String, Codable, Sendable {
  case pending
  case processing
  case completed
  case failed
  case cancelled
}

public struct DictationRequest: Codable, Equatable, Sendable {
  public let requestID: String
  public let createdAt: Date
  public let source: String
  public let status: DictationRequestStatus

  public init(
    requestID: String,
    createdAt: Date = Date(),
    source: String = "keyboard",
    status: DictationRequestStatus = .pending
  ) {
    self.requestID = requestID
    self.createdAt = createdAt
    self.source = source
    self.status = status
  }
}

public struct DictationResult: Codable, Equatable, Sendable {
  public let requestID: String
  public let completedAt: Date
  public let text: String
  public let language: String
  public let model: String
  public let error: String?

  public init(
    requestID: String,
    completedAt: Date = Date(),
    text: String,
    language: String = "auto",
    model: String = "unknown",
    error: String? = nil
  ) {
    self.requestID = requestID
    self.completedAt = completedAt
    self.text = text
    self.language = language
    self.model = model
    self.error = error
  }
}

public struct KeyboardWorkflowState: Codable, Equatable, Sendable {
  public let isProcessing: Bool
  public let lastSeenRequestID: String?
  public let lastInsertedRequestID: String?

  public init(
    isProcessing: Bool = false,
    lastSeenRequestID: String? = nil,
    lastInsertedRequestID: String? = nil
  ) {
    self.isProcessing = isProcessing
    self.lastSeenRequestID = lastSeenRequestID
    self.lastInsertedRequestID = lastInsertedRequestID
  }
}

public enum DictationSharedRecord: String, CaseIterable, Sendable {
  case request = "dictation_request"
  case result = "dictation_result"
  case keyboardState = "keyboard_state"
}

public enum VoiceyiOSConstants {
  public static let appGroupIdentifier = "group.work.voicey.shared"
  public static let appURLScheme = "voicey"
  public static let dictationRouteHost = "dictation"
  public static let dictationRouteStartPath = "/start"
  public static let dictationRequestTimeoutSeconds: TimeInterval = 600
}
