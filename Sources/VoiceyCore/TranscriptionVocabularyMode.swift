import Foundation

/// How custom vocabulary and on-screen terms are applied during dictation.
public enum TranscriptionVocabularyMode: String, CaseIterable, Sendable {
  /// Pass a compact decoder context into Qwen3 ASR before transcription (default).
  case decoderSteering
  /// Skip ASR steering; correct spelling with a local LM Studio chat model after transcription.
  case lmStudioPostProcess

  public var displayName: String {
    switch self {
    case .decoderSteering:
      return "During transcription"
    case .lmStudioPostProcess:
      return "After transcription (LM Studio)"
    }
  }
}
