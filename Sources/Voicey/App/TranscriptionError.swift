import Foundation

enum TranscriptionError: LocalizedError {
  case transcriptionFailed(String)
  case modelNotLoaded
  case audioCaptureFailed

  var errorDescription: String? {
    switch self {
    case .transcriptionFailed(let reason):
      return "Transcription failed: \(reason)"
    case .modelNotLoaded:
      return "No transcription model loaded"
    case .audioCaptureFailed:
      return "Failed to capture audio"
    }
  }
}
