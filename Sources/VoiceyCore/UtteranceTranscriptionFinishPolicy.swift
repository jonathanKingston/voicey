import Foundation

/// How captured audio is handed to transcription after an utterance ends.
public enum CapturedAudioFinishRoute: Equatable {
  case sharedPCMHandle
  case incrementalCoordinatorFlush
}

/// Finish-route policy for manual hotkey vs hands-free utterances.
///
/// Regression guards:
/// - #129: Rust `voicey-capture` manual hotkey without streamed incremental audio must use the
///   shared PCM handle, not an empty `flushAndFinish`.
/// - #163: Hands-free utterances must finish from the drained PCM slice (pre-roll + bounds), not
///   a partial incremental buffer when streaming was gated during `waitingForSpeech` / flush barrier.
public enum UtteranceTranscriptionFinishPolicy {
  public static func route(isSharedBuffer: Bool) -> CapturedAudioFinishRoute {
    isSharedBuffer ? .sharedPCMHandle : .incrementalCoordinatorFlush
  }

  /// When true, complete the utterance by transcribing the shared PCM / in-memory capture handle.
  public static func shouldFinishViaSharedPCMTranscription(
    route: CapturedAudioFinishRoute,
    hasBufferedIncrementalAudio: Bool,
    handsFreeUtterance: Bool
  ) -> Bool {
    switch route {
    case .incrementalCoordinatorFlush:
      return false
    case .sharedPCMHandle:
      if handsFreeUtterance {
        return true
      }
      return !hasBufferedIncrementalAudio
    }
  }

  /// When true, complete via `IncrementalTranscriptionCoordinator.flushAndFinish`.
  public static func shouldFinishViaIncrementalFlush(
    route: CapturedAudioFinishRoute,
    hasBufferedIncrementalAudio: Bool,
    handsFreeUtterance: Bool
  ) -> Bool {
    switch route {
    case .incrementalCoordinatorFlush:
      return true
    case .sharedPCMHandle:
      if handsFreeUtterance {
        return false
      }
      return hasBufferedIncrementalAudio
    }
  }
}
