import Foundation
import VoiceyCore
import VoiceySpeechApple

@MainActor
final class IOSDictationViewModel: ObservableObject {
  @Published var statusMessage = "Idle"
  @Published var pendingRequestID: String?
  @Published var lastPublishedResult: String?
  @Published var setupErrorMessage: String?
  @Published var isRecording = false

  private let store: SharedContainerStore?
  private let speechEngine: AppleSpeechRecognizerEngine
  private let coordinator: TranscriptionCoordinator
  private var activeRequestID: String?

  init() {
    let speechEngine = AppleSpeechRecognizerEngine()
    self.speechEngine = speechEngine
    self.coordinator = TranscriptionCoordinator(
      audioCapturer: IOSAudioCapturer(),
      speechEngine: speechEngine,
      textDeliverer: IOSNoOpTextDeliverer()
    )

    do {
      self.store = try SharedContainerStore()
    } catch {
      self.store = nil
      self.setupErrorMessage = error.localizedDescription
      self.statusMessage = "App Group unavailable"
    }
  }

  func handleIncomingURL(_ url: URL) {
    guard let route = DictationRoute.parse(url: url) else {
      return
    }

    switch route {
    case .startDictation:
      statusMessage = "Opened from keyboard request"
      beginProcessingFromKeyboardHandoff()
    }
  }

  private func beginProcessingFromKeyboardHandoff() {
    Task {
      guard let store else { return }
      do {
        try await store.purgeExpiredRequest()
        guard let request = try await store.loadRequest() else {
          statusMessage = "No request available"
          pendingRequestID = nil
          return
        }

        pendingRequestID = request.requestID
        switch request.status {
        case .pending:
          try await store.markRequestProcessing(requestID: request.requestID)
          statusMessage = "Request processing, tap Start Recording"
        case .processing:
          statusMessage = "Request processing, tap Start Recording"
        case .completed:
          statusMessage = "Request completed"
        case .failed:
          statusMessage = "Request failed"
        case .cancelled:
          statusMessage = "Request cancelled"
        }
      } catch {
        statusMessage = "Failed to process request"
      }
    }
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

  func startRecordingFromPendingRequest() {
    Task {
      guard let store else { return }
      do {
        guard let request = try await store.loadRequest() else {
          statusMessage = "No request available"
          return
        }

        switch request.status {
        case .pending:
          try await store.markRequestProcessing(requestID: request.requestID)
        case .processing:
          break
        case .completed, .failed, .cancelled:
          statusMessage = "Create a new keyboard request first"
          return
        }

        try await coordinator.startRecording(requestID: request.requestID)
        activeRequestID = request.requestID
        pendingRequestID = request.requestID
        isRecording = true
        statusMessage = "Recording..."
      } catch {
        statusMessage = "Failed to start recording"
      }
    }
  }

  func stopRecordingAndPublishResult() {
    Task {
      guard let store else { return }
      guard isRecording else {
        statusMessage = "Not currently recording"
        return
      }

      guard let requestID = activeRequestID else {
        statusMessage = "Missing request context"
        isRecording = false
        return
      }

      do {
        try await coordinator.stopRecording()

        let coordinatorState = await coordinator.state
        switch coordinatorState {
        case .completed(let text, let metadata):
          try await store.markRequestCompleted(
            requestID: requestID,
            text: text,
            language: metadata.language,
            model: metadata.modelIdentifier
          )
          _ = try await store.markKeyboardIdle(lastSeenRequestID: requestID)
          lastPublishedResult = text
          statusMessage = "Result published"
        case .failed(let message):
          try await store.markRequestFailed(
            requestID: requestID,
            errorMessage: message,
            language: "auto",
            model: speechEngine.identifier
          )
          _ = try await store.markKeyboardIdle(lastSeenRequestID: requestID)
          statusMessage = "Request failed"
        default:
          statusMessage = "Dictation did not complete"
        }
      } catch {
        try? await store.markRequestFailed(
          requestID: requestID,
          errorMessage: error.localizedDescription,
          language: "auto",
          model: speechEngine.identifier
        )
        _ = try? await store.markKeyboardIdle(lastSeenRequestID: requestID)
        statusMessage = "Failed to stop recording"
      }

      isRecording = false
      activeRequestID = nil
      refreshState()
    }
  }

  func cancelRecording() {
    Task {
      guard let store else { return }
      await coordinator.cancel()

      if let requestID = activeRequestID {
        try? await store.markRequestFailed(
          requestID: requestID,
          errorMessage: "Dictation cancelled",
          language: "auto",
          model: speechEngine.identifier
        )
        _ = try? await store.markKeyboardIdle(lastSeenRequestID: requestID)
      }

      isRecording = false
      activeRequestID = nil
      statusMessage = "Recording cancelled"
      refreshState()
    }
  }

  func clearSharedRecords() {
    Task {
      guard let store else { return }
      do {
        await coordinator.cancel()
        isRecording = false
        activeRequestID = nil
        try await store.clearAllRecords()
        pendingRequestID = nil
        lastPublishedResult = nil
        statusMessage = "Shared records cleared"
      } catch {
        statusMessage = "Failed to clear records"
      }
    }
  }
}
