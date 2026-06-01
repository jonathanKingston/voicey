import Foundation
import VoiceyCore
import os

/// Holds the latest accessibility snapshot captured at record start for Qwen steering.
final class ScreenContextStore: @unchecked Sendable {
  static let shared = ScreenContextStore()

  private let lock = NSLock()
  private var snapshot: ScreenContextSnapshot?
  private var exposure: ScreenContextExposureAssessment.Result?

  private init() {}

  func set(_ snapshot: ScreenContextSnapshot, exposure: ScreenContextExposureAssessment.Result? = nil) {
    lock.lock()
    defer { lock.unlock() }
    self.snapshot = snapshot
    self.exposure = exposure
  }

  func clear() {
    lock.lock()
    defer { lock.unlock() }
    snapshot = nil
    exposure = nil
  }

  /// Last exposure assessment for the captured snapshot (consumed with the snapshot).
  func consumeExposureAssessment() -> ScreenContextExposureAssessment.Result? {
    lock.lock()
    defer { lock.unlock() }
    let value = exposure
    exposure = nil
    return value
  }

  /// Returns the accessibility snapshot captured at record start without clearing it.
  ///
  /// The snapshot is cleared at recording boundaries via `clear()` (see `AppDelegate`
  /// screen-context capture). Incremental transcription reads the same snapshot for every
  /// pause-separated chunk in one session.
  func currentSnapshot() -> ScreenContextSnapshot? {
    lock.lock()
    defer { lock.unlock() }
    return snapshot
  }

  /// Consumes and returns the accessibility snapshot captured at record start.
  func consumeSnapshot() -> ScreenContextSnapshot? {
    lock.lock()
    defer { lock.unlock() }
    let captured = snapshot
    snapshot = nil
    return captured
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
