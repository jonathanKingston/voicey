import Combine
import Foundation

struct HandsFreeBackgroundTranscriptionJob: Identifiable, Equatable {
  let id: UUID
  let envelope: [Float]
  let startedAt: Date
  let audioDuration: TimeInterval
  let estimatedRTF: Double
}

/// Represents the current state of the transcription process
enum TranscriptionState: Equatable {
  /// No transcription in progress
  case idle

  /// Loading the Whisper model (first-time warmup)
  case loadingModel

  /// Armed and waiting for the user to begin speaking.
  case waitingForSpeech(startTime: Date)

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

  /// Whether we're armed and waiting for speech in hands-free mode
  var isWaitingForSpeech: Bool {
    if case .waitingForSpeech = self { return true }
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

  /// Whether we're in an active state (loading, waiting, recording or processing)
  var isActive: Bool {
    switch self {
    case .loadingModel, .waitingForSpeech, .recording, .processing:
      return true
    case .idle, .completed, .error:
      return false
    }
  }

  /// Whether microphone capture is currently engaged.
  var isCaptureEngaged: Bool {
    switch self {
    case .waitingForSpeech, .recording:
      return true
    case .idle, .loadingModel, .processing, .completed, .error:
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
      return L10n.State.ready
    case .loadingModel:
      return L10n.State.loadingModel
    case .waitingForSpeech:
      return L10n.State.waitingForSpeech
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
  /// Hands-free hotkey session: mic stays open across utterances until cancelled.
  @Published var handsFreeSessionActive: Bool = false
  /// In-flight utterance transcriptions while the mic stays open in hands-free mode.
  @Published private(set) var handsFreeBackgroundTranscriptionJobs: [HandsFreeBackgroundTranscriptionJob] =
    []
  @Published var audioLevel: Float = 0.0
  @Published var currentModel: SpeechModel = SettingsManager.shared.selectedModel
  @Published var lastTranscription: String = ""
  @Published var partialTranscription: String = ""
  @Published var isCatchingUpTranscription: Bool = false

  /// Model loading status - for startup warmup indication
  @Published var modelStatus: ModelStatus = .notDownloaded

  /// Normalized bar heights for the clip being transcribed (see `AudioWaveformEnvelope`).
  @Published private(set) var recordingWaveformEnvelope: [Float] = []

  /// Duration of the captured clip in seconds (16 kHz sample count / rate).
  @Published private(set) var recordingAudioDuration: TimeInterval = 0

  /// Wall-clock start of the in-flight Qwen transcription (overlay progress).
  @Published private(set) var transcriptionProcessingStartedAt: Date?

  /// Expected processing time / audio duration used to animate overlay progress.
  @Published private(set) var transcriptionProcessingEstimateRTF: Double = 1.0

  private var recentQwenTranscriptionRTFs: [Double] = []
  private let maxRecentQwenTranscriptionRTFs = 5

  // MARK: - Convenience Accessors

  /// Whether we're currently recording (delegates to transcriptionState)
  var isRecording: Bool {
    transcriptionState.isRecording
  }

  var isWaitingForSpeech: Bool {
    transcriptionState.isWaitingForSpeech
  }

  var isCaptureEngaged: Bool {
    handsFreeSessionActive || transcriptionState.isCaptureEngaged
  }

  var isHandsFreeBackgroundTranscribing: Bool {
    handsFreeSessionActive && !handsFreeBackgroundTranscriptionJobs.isEmpty
  }

  private(set) var handsFreeIncrementalFlushBarrierCount = 0

  /// True while `flushAndFinish` is in flight (background job and/or barrier).
  /// Intentionally independent of `handsFreeSessionActive` so session teardown does not call `cancel()` mid-flush.
  var isHandsFreeUtteranceFlushInProgress: Bool {
    !handsFreeBackgroundTranscriptionJobs.isEmpty
      || handsFreeIncrementalFlushBarrierCount > 0
  }

  func beginHandsFreeIncrementalFlushBarrier() {
    handsFreeIncrementalFlushBarrierCount += 1
  }

  func endHandsFreeIncrementalFlushBarrier() {
    handsFreeIncrementalFlushBarrierCount = max(0, handsFreeIncrementalFlushBarrierCount - 1)
  }

  @discardableResult
  func addHandsFreeBackgroundTranscriptionJob(
    envelope: [Float],
    audioDuration: TimeInterval,
    estimatedRTF: Double
  ) -> UUID {
    let job = HandsFreeBackgroundTranscriptionJob(
      id: UUID(),
      envelope: envelope,
      startedAt: Date(),
      audioDuration: audioDuration,
      estimatedRTF: max(estimatedRTF, 0.05)
    )
    handsFreeBackgroundTranscriptionJobs.append(job)
    return job.id
  }

  func removeHandsFreeBackgroundTranscriptionJob(id: UUID) {
    handsFreeBackgroundTranscriptionJobs.removeAll { $0.id == id }
  }

  func resetHandsFreeBackgroundTranscriptionJobs() {
    handsFreeBackgroundTranscriptionJobs = []
  }

  /// Whether the app is ready to record (model loaded and permissions granted)
  var isReadyToRecord: Bool {
    modelStatus.isReady
  }

  // MARK: - Overlay waveform / progress

  var averageQwenTranscriptionRTF: Double? {
    guard !recentQwenTranscriptionRTFs.isEmpty else { return nil }
    let sum = recentQwenTranscriptionRTFs.reduce(0, +)
    return sum / Double(recentQwenTranscriptionRTFs.count)
  }

  func prepareTranscriptionProgressDisplay(
    envelope: [Float],
    audioDuration: TimeInterval,
    estimatedRTF: Double
  ) {
    recordingWaveformEnvelope = envelope
    recordingAudioDuration = audioDuration
    transcriptionProcessingEstimateRTF = max(estimatedRTF, 0.05)
    transcriptionProcessingStartedAt = Date()
  }

  func recordQwenTranscriptionRTF(_ rtf: Double) {
    guard rtf > 0 else { return }
    recentQwenTranscriptionRTFs.append(rtf)
    if recentQwenTranscriptionRTFs.count > maxRecentQwenTranscriptionRTFs {
      recentQwenTranscriptionRTFs.removeFirst()
    }
  }

  func clearRecordingWaveformDisplay() {
    recordingWaveformEnvelope = []
    recordingAudioDuration = 0
    transcriptionProcessingStartedAt = nil
    transcriptionProcessingEstimateRTF = 1.0
  }

  static func defaultEstimatedRTF(for model: SpeechModel) -> Double {
    switch model {
    case .qwen3Small:
      return 0.65
    case .qwen3Large:
      return 1.05
    default:
      return 1.0
    }
  }
}
