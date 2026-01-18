import Combine
import Foundation

/// Represents the current state of the transcription process
enum TranscriptionState: Equatable {
  /// No transcription in progress
  case idle

  /// Loading the Whisper model (first-time warmup)
  case loadingModel

  /// Currently recording audio
  /// - Parameter startTime: When recording started (for duration tracking)
  case recording(startTime: Date)

  /// Processing recorded audio
  case processing

  /// Transcription completed successfully
  /// - Parameter text: The transcribed text
  case completed(text: String)

  /// Transcription failed
  /// - Parameter message: Error description
  case error(message: String)

  // MARK: - Convenience Properties

  /// Whether we're currently recording
  var isRecording: Bool {
    if case .recording = self { return true }
    return false
  }

  /// Whether we're currently processing
  var isProcessing: Bool {
    if case .processing = self { return true }
    return false
  }

  /// Whether we're loading the model
  var isLoadingModel: Bool {
    if case .loadingModel = self { return true }
    return false
  }

  /// Whether we're in an active state (loading, recording or processing)
  var isActive: Bool {
    switch self {
    case .loadingModel, .recording, .processing:
      return true
    case .idle, .completed, .error:
      return false
    }
  }

  /// Recording duration if currently recording
  var recordingDuration: TimeInterval? {
    if case .recording(let startTime) = self {
      return Date().timeIntervalSince(startTime)
    }
    return nil
  }

  /// Display text for the current state
  var displayText: String {
    switch self {
    case .idle:
      return "Ready"
    case .loadingModel:
      return "Loading model..."
    case .recording:
      return "Listening..."
    case .processing:
      return "Transcribing..."
    case .completed:
      return "Done"
    case .error(let message):
      return "Error: \(message)"
    }
  }
}

/// Model readiness status - shown in status bar
enum ModelStatus: Equatable {
  case notDownloaded
  case loading
  case ready
  case failed(String)

  var isReady: Bool {
    if case .ready = self { return true }
    return false
  }

  var isLoading: Bool {
    if case .loading = self { return true }
    return false
  }

  var statusText: String {
    switch self {
    case .notDownloaded: return "No model"
    case .loading: return "Loading..."
    case .ready: return "Ready"
    case .failed(let error): return "Error: \(error)"
    }
  }
}

/// Holds the observable application state
final class AppState: ObservableObject {
  @Published var transcriptionState: TranscriptionState = .idle
  @Published var audioLevel: Float = 0.0
  @Published var currentModel: WhisperModel = SettingsManager.shared.selectedModel
  @Published var lastTranscription: String = ""

  /// Model loading status - for startup warmup indication
  @Published var modelStatus: ModelStatus = .notDownloaded

  // MARK: - Convenience Accessors

  /// Whether we're currently recording (delegates to transcriptionState)
  var isRecording: Bool {
    transcriptionState.isRecording
  }

  /// Whether the app is ready to record (model loaded and permissions granted)
  var isReadyToRecord: Bool {
    modelStatus.isReady
  }
}
