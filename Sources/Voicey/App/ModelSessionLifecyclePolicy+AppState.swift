import Foundation

extension AppState {
  /// True while transcription, hands-free capture, or a hands-free flush owns the session.
  var isTranscriptionSessionBusy: Bool {
    transcriptionState.isActive
      || handsFreeSessionActive
      || isHandsFreeUtteranceFlushInProgress
  }

  func modelSessionLifecyclePolicy(isModelEngineSwitchInProgress: Bool) -> ModelSessionLifecyclePolicy {
    ModelSessionLifecyclePolicy(
      isModelEngineSwitchInProgress: isModelEngineSwitchInProgress,
      isTranscriptionSessionBusy: isTranscriptionSessionBusy
    )
  }
}
