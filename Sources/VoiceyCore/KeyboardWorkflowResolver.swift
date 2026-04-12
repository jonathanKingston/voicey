import Foundation

public struct KeyboardWorkflowPresentation: Equatable, Sendable {
  public let statusMessage: String
  public let canRequestDictation: Bool
  public let canInsertLatest: Bool

  public init(
    statusMessage: String,
    canRequestDictation: Bool,
    canInsertLatest: Bool
  ) {
    self.statusMessage = statusMessage
    self.canRequestDictation = canRequestDictation
    self.canInsertLatest = canInsertLatest
  }
}

public enum KeyboardWorkflowResolver {
  public static func resolve(
    hasFullAccess: Bool,
    request: DictationRequest?,
    result: DictationResult?,
    keyboardState: KeyboardWorkflowState?
  ) -> KeyboardWorkflowPresentation {
    guard hasFullAccess else {
      return KeyboardWorkflowPresentation(
        statusMessage: "Enable Full Access in Settings",
        canRequestDictation: false,
        canInsertLatest: false
      )
    }

    if let request, request.status == .pending || request.status == .processing {
      return KeyboardWorkflowPresentation(
        statusMessage: "Request \(request.status.rawValue)",
        canRequestDictation: false,
        canInsertLatest: false
      )
    }

    guard let result else {
      return KeyboardWorkflowPresentation(
        statusMessage: "Idle",
        canRequestDictation: true,
        canInsertLatest: false
      )
    }

    if let error = result.error {
      return KeyboardWorkflowPresentation(
        statusMessage: "Last request failed: \(error)",
        canRequestDictation: true,
        canInsertLatest: false
      )
    }

    guard result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
      return KeyboardWorkflowPresentation(
        statusMessage: "Result text is empty",
        canRequestDictation: true,
        canInsertLatest: false
      )
    }

    if let lastSeenRequestID = keyboardState?.lastSeenRequestID,
      lastSeenRequestID != result.requestID
    {
      return KeyboardWorkflowPresentation(
        statusMessage: "Stale result available",
        canRequestDictation: true,
        canInsertLatest: false
      )
    }

    if keyboardState?.lastInsertedRequestID == result.requestID {
      return KeyboardWorkflowPresentation(
        statusMessage: "Transcript inserted",
        canRequestDictation: true,
        canInsertLatest: false
      )
    }

    return KeyboardWorkflowPresentation(
      statusMessage: "Result ready",
      canRequestDictation: true,
      canInsertLatest: true
    )
  }
}
