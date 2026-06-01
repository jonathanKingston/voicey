import Foundation

/// Inputs that determine whether an active transcription session blocks model engine changes.
///
/// Mirrors `AppState.isTranscriptionSessionBusy` so recording, hands-free session, and
/// in-flight flush states are covered by Linux `VoiceyCore` tests. See
/// `docs/explorations/model-session-lifecycle-races.md` and issue #139.
public struct TranscriptionSessionBusySignals: Equatable {
  public var transcriptionStateIsActive: Bool
  public var handsFreeSessionActive: Bool
  public var handsFreeUtteranceFlushInProgress: Bool

  public init(
    transcriptionStateIsActive: Bool,
    handsFreeSessionActive: Bool,
    handsFreeUtteranceFlushInProgress: Bool
  ) {
    self.transcriptionStateIsActive = transcriptionStateIsActive
    self.handsFreeSessionActive = handsFreeSessionActive
    self.handsFreeUtteranceFlushInProgress = handsFreeUtteranceFlushInProgress
  }

  public var isTranscriptionSessionBusy: Bool {
    transcriptionStateIsActive
      || handsFreeSessionActive
      || handsFreeUtteranceFlushInProgress
  }

  public func modelSessionLifecyclePolicy(
    isModelEngineSwitchInProgress: Bool
  ) -> ModelSessionLifecyclePolicy {
    ModelSessionLifecyclePolicy(
      isModelEngineSwitchInProgress: isModelEngineSwitchInProgress,
      isTranscriptionSessionBusy: isTranscriptionSessionBusy
    )
  }
}
