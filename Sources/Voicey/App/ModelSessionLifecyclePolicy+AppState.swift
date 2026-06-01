import Foundation
import VoiceyCore

extension AppState {
  /// True while transcription, hands-free capture, or a hands-free flush owns the session.
  var isTranscriptionSessionBusy: Bool {
    TranscriptionSessionBusySignals(
      transcriptionStateIsActive: transcriptionState.isActive,
      handsFreeSessionActive: handsFreeSessionActive,
      handsFreeUtteranceFlushInProgress: isHandsFreeUtteranceFlushInProgress
    ).isTranscriptionSessionBusy
  }

  func modelSessionLifecyclePolicy(isModelEngineSwitchInProgress: Bool) -> ModelSessionLifecyclePolicy {
    ModelSessionLifecyclePolicy(
      isModelEngineSwitchInProgress: isModelEngineSwitchInProgress,
      isTranscriptionSessionBusy: isTranscriptionSessionBusy
    )
  }
}
