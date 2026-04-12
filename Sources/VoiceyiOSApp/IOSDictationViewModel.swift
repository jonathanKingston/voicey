import Foundation

@MainActor
final class IOSDictationViewModel: ObservableObject {
  @Published var statusMessage = "Idle"
  @Published var pendingRequestID: String?
  @Published var draftTranscript = ""
  @Published var lastPublishedResult: String?
  @Published var setupErrorMessage: String?

  private let store: SharedContainerStore?

  init() {
    do {
      self.store = try SharedContainerStore()
    } catch {
      self.store = nil
      self.setupErrorMessage = error.localizedDescription
      self.statusMessage = "App Group unavailable"
    }
  }

  func handleIncomingURL(_ url: URL) {
    guard url.scheme == VoiceyiOSConstants.appURLScheme else {
      return
    }

    guard url.host == "dictation" else {
      return
    }

    guard url.path == "/start" else {
      return
    }

    statusMessage = "Opened from keyboard request"
    refreshState()
  }

  func refreshState() {
    Task {
      guard let store else { return }
      do {
        try await store.purgeExpiredRequest()

        let request = try await store.loadRequest()
        let result = try await store.loadResult()

        pendingRequestID = request?.requestID
        if let request {
          statusMessage = "Request \(request.status.rawValue)"
        } else {
          statusMessage = "Idle"
        }

        if let result {
          lastPublishedResult = result.text
        }
      } catch {
        statusMessage = "Failed to refresh state"
      }
    }
  }

  func markRequestProcessing() {
    Task {
      guard let store else { return }
      do {
        guard let request = try await store.loadRequest() else {
          statusMessage = "No pending request"
          return
        }
        let processingRequest = DictationRequest(
          requestID: request.requestID,
          createdAt: request.createdAt,
          source: request.source,
          status: .processing
        )
        try await store.saveRequest(processingRequest)
        statusMessage = "Request processing"
      } catch {
        statusMessage = "Failed to mark processing"
      }
    }
  }

  func publishResult() {
    Task {
      guard let store else { return }
      do {
        guard let request = try await store.loadRequest() else {
          statusMessage = "No request available"
          return
        }

        let trimmedTranscript = draftTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else {
          statusMessage = "Transcript is required"
          return
        }

        let result = DictationResult(
          requestID: request.requestID,
          text: trimmedTranscript,
          language: "auto",
          model: "ios-manual-entry"
        )
        let completedRequest = DictationRequest(
          requestID: request.requestID,
          createdAt: request.createdAt,
          source: request.source,
          status: .completed
        )

        try await store.saveResult(result)
        try await store.saveRequest(completedRequest)
        try await store.saveKeyboardState(
          KeyboardWorkflowState(
            isProcessing: false,
            lastSeenRequestID: request.requestID,
            lastInsertedRequestID: nil
          ))

        lastPublishedResult = trimmedTranscript
        statusMessage = "Result published"
        draftTranscript = ""
      } catch {
        statusMessage = "Failed to publish result"
      }
    }
  }

  func clearSharedRecords() {
    Task {
      guard let store else { return }
      do {
        try await store.clearAllRecords()
        pendingRequestID = nil
        lastPublishedResult = nil
        draftTranscript = ""
        statusMessage = "Shared records cleared"
      } catch {
        statusMessage = "Failed to clear records"
      }
    }
  }
}
