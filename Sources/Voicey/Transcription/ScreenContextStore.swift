import Foundation
import VoiceyCore
import os

/// Holds the latest accessibility snapshot captured at record start for Qwen steering.
final class ScreenContextStore: @unchecked Sendable {
  static let shared = ScreenContextStore()

  private let lock = NSLock()
  private var snapshot: ScreenContextSnapshot?
  private var exposure: ScreenContextExposureAssessment.Result?
  private var captureSessionToken: UInt64 = 0
  private let captureGate = ScreenContextCaptureGate()

  private init() {}

  /// Clears stored context and starts a capture gate for the new recording.
  @discardableResult
  func beginCaptureSession() -> UInt64 {
    lock.lock()
    defer { lock.unlock() }
    snapshot = nil
    exposure = nil
    let token = captureGate.beginSession()
    captureSessionToken = token
    return token
  }

  /// Ends the capture gate without waiting (screen context disabled or prerequisites missing).
  func deactivateCaptureSession() {
    captureGate.deactivateSession()
  }

  /// Signals that the detached capture task finished (or was skipped with an empty snapshot).
  func markCaptureComplete(sessionToken: UInt64) {
    captureGate.markReady(sessionToken: sessionToken)
  }

  /// Waits up to `ScreenContextCaptureGate.defaultWaitNanoseconds` when a capture session is active.
  func waitForCaptureIfNeeded() async -> ScreenContextCaptureWaitOutcome {
    await captureGate.waitForReady()
  }

  func set(
    _ snapshot: ScreenContextSnapshot,
    exposure: ScreenContextExposureAssessment.Result? = nil,
    sessionToken: UInt64? = nil
  ) {
    lock.lock()
    defer { lock.unlock() }
    if let sessionToken, sessionToken != captureSessionToken { return }
    self.snapshot = snapshot
    self.exposure = exposure
  }

  func clear() {
    lock.lock()
    defer { lock.unlock() }
    snapshot = nil
    exposure = nil
    captureGate.reset()
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
