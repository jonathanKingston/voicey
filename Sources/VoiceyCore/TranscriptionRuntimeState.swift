import Foundation

/// Represents the runtime lifecycle of a transcription interaction.
/// This is intentionally UI-framework agnostic so it can be shared across platforms.
public enum TranscriptionRuntimeState: Equatable, Sendable {
  case idle
  case loadingModel
  case recording(startTime: Date)
  case processing
  case completed(text: String)
  case error(message: String)

  public var isRecording: Bool {
    if case .recording = self { return true }
    return false
  }

  public var isProcessing: Bool {
    if case .processing = self { return true }
    return false
  }

  public var isLoadingModel: Bool {
    if case .loadingModel = self { return true }
    return false
  }

  public var isActive: Bool {
    switch self {
    case .loadingModel, .recording, .processing:
      return true
    case .idle, .completed, .error:
      return false
    }
  }

  public var recordingDuration: TimeInterval? {
    if case .recording(let startTime) = self {
      return Date().timeIntervalSince(startTime)
    }
    return nil
  }
}
