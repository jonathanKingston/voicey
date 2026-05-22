import Foundation
import VoiceyCore
import os

/// Holds the latest accessibility snapshot captured at record start for Qwen steering.
final class ScreenContextStore: @unchecked Sendable {
  static let shared = ScreenContextStore()

  private let lock = NSLock()
  private var snapshot: ScreenContextSnapshot?

  private init() {}

  func set(_ snapshot: ScreenContextSnapshot) {
    lock.lock()
    defer { lock.unlock() }
    self.snapshot = snapshot
  }

  func clear() {
    lock.lock()
    defer { lock.unlock() }
    snapshot = nil
  }

  /// Consumes the snapshot and returns BM25-ranked screen terms (manual glossary is query-only).
  func consumeScreenTerms(
    manualGlossaryForQuery: String,
    maxTerms: Int = ScreenTermSelector.defaultMaxTerms
  ) -> [String] {
    lock.lock()
    let captured = snapshot
    snapshot = nil
    lock.unlock()

    return ScreenTermSelector.select(
      snapshot: captured,
      manualGlossary: manualGlossaryForQuery,
      manualGlossaryEnabled: false,
      maxTerms: maxTerms
    )
  }
}
