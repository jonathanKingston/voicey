import Foundation

public enum TranscriptionCoordinatorError: LocalizedError, Equatable {
  case missingRequestContext
  case emptyTranscription

  public var errorDescription: String? {
    switch self {
    case .missingRequestContext:
      return "No transcription request context is active."
    case .emptyTranscription:
      return "Transcription text is empty."
    }
  }
}

public actor TranscriptionCoordinator: TranscriptionCoordinating {
  public private(set) var state: TranscriptionSessionState

  private let audioCapturer: AudioCapturing
  private let speechEngine: SpeechEngine
  private let textDeliverer: TextDelivering
  private let dateProvider: @Sendable () -> Date
  private var activeRequestID: String?

  public init(
    audioCapturer: AudioCapturing,
    speechEngine: SpeechEngine,
    textDeliverer: TextDelivering,
    initialState: TranscriptionSessionState = .idle,
    dateProvider: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.audioCapturer = audioCapturer
    self.speechEngine = speechEngine
    self.textDeliverer = textDeliverer
    self.state = initialState
    self.dateProvider = dateProvider
  }

  public func startRecording(requestID: String) async throws {
    guard requestID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
      throw TranscriptionSessionTransitionError.emptyRequestIdentifier
    }

    try audioCapturer.start()
    do {
      state = try TranscriptionSessionReducer.reduce(
        state,
        event: .startRecording(startedAt: dateProvider())
      )
      activeRequestID = requestID
    } catch {
      _ = try? audioCapturer.stop()
      activeRequestID = nil
      throw error
    }
  }

  public func stopRecording() async throws {
    guard let requestID = activeRequestID else {
      throw TranscriptionCoordinatorError.missingRequestContext
    }

    state = try TranscriptionSessionReducer.reduce(state, event: .startProcessing(requestID: requestID))

    do {
      let samples = try audioCapturer.stop()
      let result = try await speechEngine.transcribe(samples: samples)
      let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard text.isEmpty == false else {
        throw TranscriptionCoordinatorError.emptyTranscription
      }

      try await textDeliverer.deliver(text: text)

      let metadata = TranscriptionSessionMetadata(
        language: result.language,
        modelIdentifier: "unknown",
        processingTime: result.processingTime
      )
      state = try TranscriptionSessionReducer.reduce(
        state,
        event: .complete(text: text, metadata: metadata)
      )
      activeRequestID = nil
    } catch {
      state = (try? TranscriptionSessionReducer.reduce(
        state,
        event: .fail(message: error.localizedDescription)
      )) ?? .failed(message: error.localizedDescription)
      activeRequestID = nil
      throw error
    }
  }

  public func cancel() async {
    _ = try? audioCapturer.stop()
    state = (try? TranscriptionSessionReducer.reduce(state, event: .cancel)) ?? .idle
    activeRequestID = nil
  }
}
