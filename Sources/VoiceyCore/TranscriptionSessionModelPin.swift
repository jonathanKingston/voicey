import Foundation

/// Pins the model used for an in-flight utterance so settings changes cannot retarget transcription.
///
/// See `docs/explorations/model-session-lifecycle-races.md` and issue #139.
public struct TranscriptionSessionModelPin<Model: Equatable>: Equatable {
  private(set) var pinned: Model?

  public init(pinned: Model? = nil) {
    self.pinned = pinned
  }

  public mutating func pin(_ model: Model) {
    pinned = model
  }

  public mutating func clear() {
    pinned = nil
  }

  public func resolved(fallback: Model) -> Model {
    pinned ?? fallback
  }
}
