import Foundation

/// An AX text observation, never a value to write back into an editor.
public struct PasteTextSnapshot: Equatable, Sendable {
  public let value: String
  public let selection: NSRange

  public init(value: String, selection: NSRange) {
    self.value = value
    self.selection = selection
  }

  public func inserting(_ text: String) -> PasteTextSnapshot? {
    let source = value as NSString
    guard selection.location != NSNotFound,
          selection.location >= 0, selection.length >= 0,
          selection.location <= source.length,
          selection.length <= source.length - selection.location else { return nil }
    return PasteTextSnapshot(
      value: source.replacingCharacters(in: selection, with: text),
      selection: NSRange(location: selection.location + text.utf16.count, length: 0)
    )
  }
}

public enum PasteAttemptOutcome: String, Sendable {
  case confirmed
  case unconfirmed
  case notAttempted
}

/// Dependency boundary for a single clipboard paste. Posting an event is not delivery evidence.
@MainActor
public protocol PasteAttemptEnvironment {
  var targetIsActive: Bool { get }
  func snapshot() -> PasteTextSnapshot?
  func postPaste() -> Bool
  func waitForObservation() async
}

public enum PasteAttempt {
  @MainActor
  public static func perform(
    text: String, environment: any PasteAttemptEnvironment, observationLimit: Int = 50,
    unobservableSettleLimit: Int = 5
  ) async -> PasteAttemptOutcome {
    guard environment.targetIsActive else { return .notAttempted }
    let before = environment.snapshot()
    let expected = before?.inserting(text)
    // Check again after reading AX: focus may have changed during the query.
    guard environment.targetIsActive, environment.postPaste() else { return .notAttempted }

    // Without an AX baseline (e.g. Electron composers) confirmation is impossible; waiting the
    // full limit only keeps the transcription on the clipboard. Allow just enough time to consume it.
    let limit = expected == nil ? min(observationLimit, unobservableSettleLimit) : observationLimit
    // Never retry after dispatch, including a timeout or unchanged AX value.
    for _ in 0..<limit {
      await environment.waitForObservation()
      guard environment.targetIsActive else { return .unconfirmed }
      if let expected, expected != before, environment.snapshot() == expected {
        return .confirmed
      }
    }
    return .unconfirmed
  }
}
