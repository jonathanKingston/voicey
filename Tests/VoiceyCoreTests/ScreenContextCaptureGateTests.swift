import XCTest

@testable import VoiceyCore

final class ScreenContextCaptureGateTests: XCTestCase {
  func testInactiveWhenNoSession() async {
    let gate = ScreenContextCaptureGate()
    let outcome = await gate.waitForReady(timeoutNanoseconds: 50_000_000)
    XCTAssertEqual(outcome, .inactive)
  }

  func testReadyImmediatelyWhenAlreadyMarked() async {
    let gate = ScreenContextCaptureGate()
    gate.beginSession()
    gate.markReady()
    let outcome = await gate.waitForReady(timeoutNanoseconds: 50_000_000)
    XCTAssertEqual(outcome, .ready)
  }

  func testWaitsUntilMarkReady() async {
    let gate = ScreenContextCaptureGate()
    gate.beginSession()

    let waitTask = Task {
      await gate.waitForReady(timeoutNanoseconds: 2_000_000_000)
    }

    try? await Task.sleep(nanoseconds: 30_000_000)
    gate.markReady()

    let outcome = await waitTask.value
    XCTAssertEqual(outcome, .ready)
  }

  func testTimesOutWhenCaptureNeverCompletes() async {
    let gate = ScreenContextCaptureGate()
    gate.beginSession()
    let outcome = await gate.waitForReady(timeoutNanoseconds: 50_000_000)
    XCTAssertEqual(outcome, .timeout)
  }

  func testDeactivateSessionReturnsInactive() async {
    let gate = ScreenContextCaptureGate()
    gate.beginSession()
    gate.deactivateSession()
    let outcome = await gate.waitForReady(timeoutNanoseconds: 50_000_000)
    XCTAssertEqual(outcome, .inactive)
  }
}
