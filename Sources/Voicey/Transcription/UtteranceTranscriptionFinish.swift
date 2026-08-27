import Foundation
import VoiceyCore

/// How an utterance captured via `AudioCaptureManager` should complete transcription.
///
/// Regression guard for #129: default `voicey-capture` returns `.sharedBuffer` without
/// streaming `[Float]` into `IncrementalTranscriptionCoordinator`. Routing those utterances
/// through `flushAndFinish` alone yields empty text.
typealias UtteranceTranscriptionFinishRoute = CapturedAudioFinishRoute

enum UtteranceTranscriptionFinish {
  static func route(for capturedAudio: CapturedAudio) -> UtteranceTranscriptionFinishRoute {
    switch capturedAudio {
    case .sharedBuffer:
      return .sharedPCMHandle
    case .inMemory:
      return .incrementalCoordinatorFlush
    }
  }

  static func shouldFinishViaIncrementalFlush(
    for capturedAudio: CapturedAudio,
    hasBufferedIncrementalAudio: Bool,
    handsFreeUtterance: Bool
  ) -> Bool {
    UtteranceTranscriptionFinishPolicy.shouldFinishViaIncrementalFlush(
      route: route(for: capturedAudio),
      hasBufferedIncrementalAudio: hasBufferedIncrementalAudio,
      handsFreeUtterance: handsFreeUtterance)
  }
}

/// Transcription output plus the audio that should be archived for replay fidelity.
struct UtteranceTranscriptionFinishOutcome: Sendable {
  let result: TranscriptionResult
  let archiveAudio: CapturedAudio
}
