import Foundation

/// Outcome of waiting for per-recording screen-context capture before steering.
public enum ScreenContextCaptureWaitOutcome: Equatable, Sendable {
  /// Capture was not started for this recording (feature off or prerequisites missing).
  case inactive
  /// Capture finished before the wait budget expired.
  case ready
  /// Capture was still in flight when the wait budget expired.
  case timeout
}

/// Cooperative gate for a single screen-context capture attempt per recording.
public final class ScreenContextCaptureGate: @unchecked Sendable {
  public static let defaultWaitNanoseconds: UInt64 = 750_000_000
  private static let pollIntervalNanoseconds: UInt64 = 10_000_000

  private let lock = NSLock()
  private var sessionToken: UInt64 = 0
  private var sessionActive = false
  private var isReady = false

  public init() {}

  /// Begins a new capture session. Call when recording starts and screen context may run.
  ///
  /// Returns a token that detached capture work must pass to `markReady(sessionToken:)`.
  @discardableResult
  public func beginSession() -> UInt64 {
    lock.lock()
    defer { lock.unlock() }
    sessionToken &+= 1
    let token = sessionToken
    sessionActive = true
    isReady = false
    return token
  }

  /// Marks the session inactive without waiting (screen context disabled or blocked).
  public func deactivateSession() {
    lock.lock()
    defer { lock.unlock() }
    sessionActive = false
    isReady = false
  }

  /// Signals that capture finished (successfully or with an empty snapshot).
  public func markReady(sessionToken: UInt64) {
    lock.lock()
    defer { lock.unlock() }
    guard sessionActive, sessionToken == self.sessionToken else { return }
    isReady = true
  }

  public func reset() {
    lock.lock()
    defer { lock.unlock() }
    sessionActive = false
    isReady = false
  }

  public func waitForReady(timeoutNanoseconds: UInt64 = defaultWaitNanoseconds) async
    -> ScreenContextCaptureWaitOutcome {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    while DispatchTime.now().uptimeNanoseconds < deadline {
      if Task.isCancelled { return terminalOutcome() }

      let state = snapshotState()
      if !state.active { return .inactive }
      if state.ready { return .ready }
      try? await Task.sleep(nanoseconds: Self.pollIntervalNanoseconds)
    }

    return terminalOutcome()
  }

  /// Atomically reads the gate state for one poll iteration.
  ///
  /// Kept synchronous (and out of `waitForReady`'s async body) so `NSLock.unlock()` is never
  /// called from an async context — `unlock()` is flagged unavailable there under the Swift 6
  /// language mode, and it also sidesteps Linux Foundation lacking `NSLock.withLock`.
  private func snapshotState() -> (active: Bool, ready: Bool) {
    lock.lock()
    defer { lock.unlock() }
    return (sessionActive, isReady)
  }

  /// Resolves the outcome when polling stops (deadline reached or task cancelled).
  private func terminalOutcome() -> ScreenContextCaptureWaitOutcome {
    lock.lock()
    defer { lock.unlock() }
    guard sessionActive else { return .inactive }
    return isReady ? .ready : .timeout
  }
}
