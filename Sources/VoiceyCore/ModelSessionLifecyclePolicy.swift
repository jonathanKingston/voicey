import Foundation

/// Rules for when model swaps and recording may overlap.
///
/// See `docs/explorations/model-session-lifecycle-races.md`.
public struct ModelSessionLifecyclePolicy: Equatable {
  public var isModelEngineSwitchInProgress: Bool
  public var isTranscriptionSessionBusy: Bool

  public init(
    isModelEngineSwitchInProgress: Bool,
    isTranscriptionSessionBusy: Bool
  ) {
    self.isModelEngineSwitchInProgress = isModelEngineSwitchInProgress
    self.isTranscriptionSessionBusy = isTranscriptionSessionBusy
  }

  public var blocksRecordingStart: Bool {
    isModelEngineSwitchInProgress
  }

  public var blocksModelEngineReconfiguration: Bool {
    isModelEngineSwitchInProgress || isTranscriptionSessionBusy
  }
}
