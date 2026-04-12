import Combine
import Foundation
import VoiceyCore

typealias TranscriptionState = TranscriptionRuntimeState

extension TranscriptionRuntimeState {
  /// Display text for the current state
  var displayText: String {
    switch self {
    case .idle:
      return L10n.State.ready
    case .loadingModel:
      return L10n.State.loadingModel
    case .recording:
      return L10n.State.listening
    case .processing:
      return L10n.State.transcribing
    case .completed:
      return L10n.State.done
    case .error(let message):
      return L10n.State.error(message)
    }
  }
}

typealias ModelStatus = ModelRuntimeStatus

/// Model readiness status - shown in status bar
extension ModelRuntimeStatus {
  var statusText: String {
    switch self {
    case .notDownloaded: return L10n.ModelStatus.noModel
    case .loading: return L10n.ModelStatus.loading
    case .ready: return L10n.ModelStatus.ready
    case .failed(let error): return L10n.ModelStatus.error(error)
    }
  }
}

/// Holds the observable application state
final class AppState: ObservableObject {
  @Published var transcriptionState: TranscriptionState = .idle
  @Published var audioLevel: Float = 0.0
  @Published var currentModel: SpeechModel = SettingsManager.shared.selectedModel
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
