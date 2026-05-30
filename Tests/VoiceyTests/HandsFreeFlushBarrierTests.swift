import XCTest

@testable import Voicey

/// Locks in the `isHandsFreeUtteranceFlushInProgress` guard that protects an in-flight
/// `flushAndFinish` from a racing `coordinator.cancel()` during session teardown.
///
/// The original bug: the guard required `handsFreeSessionActive`, but `endHandsFreeSession`
/// clears that flag *before* consulting the guard, so it always read `false` and cancel() ran
/// mid-flush, dropping the just-finished utterance. The fix makes the guard independent of
/// `handsFreeSessionActive`; these tests assert that independence so it cannot regress.
@MainActor
final class HandsFreeFlushBarrierTests: XCTestCase {
  func testFlushNotInProgressByDefault() {
    let appState = AppState()
    XCTAssertFalse(appState.isHandsFreeUtteranceFlushInProgress)
  }

  func testBarrierMarksFlushInProgress() {
    let appState = AppState()

    appState.beginHandsFreeIncrementalFlushBarrier()
    XCTAssertTrue(appState.isHandsFreeUtteranceFlushInProgress)

    appState.endHandsFreeIncrementalFlushBarrier()
    XCTAssertFalse(appState.isHandsFreeUtteranceFlushInProgress)
  }

  func testNestedBarriersBalance() {
    let appState = AppState()

    appState.beginHandsFreeIncrementalFlushBarrier()
    appState.beginHandsFreeIncrementalFlushBarrier()
    XCTAssertTrue(appState.isHandsFreeUtteranceFlushInProgress)

    appState.endHandsFreeIncrementalFlushBarrier()
    XCTAssertTrue(
      appState.isHandsFreeUtteranceFlushInProgress,
      "Still one outstanding barrier; flush must remain in progress")

    appState.endHandsFreeIncrementalFlushBarrier()
    XCTAssertFalse(appState.isHandsFreeUtteranceFlushInProgress)
  }

  func testEndBarrierClampsAtZero() {
    let appState = AppState()

    appState.endHandsFreeIncrementalFlushBarrier()
    appState.endHandsFreeIncrementalFlushBarrier()
    XCTAssertFalse(appState.isHandsFreeUtteranceFlushInProgress)

    // A subsequent begin/end pair must still toggle correctly (count never went negative).
    appState.beginHandsFreeIncrementalFlushBarrier()
    XCTAssertTrue(appState.isHandsFreeUtteranceFlushInProgress)
    appState.endHandsFreeIncrementalFlushBarrier()
    XCTAssertFalse(appState.isHandsFreeUtteranceFlushInProgress)
  }

  func testBackgroundJobMarksFlushInProgress() {
    let appState = AppState()

    let id = appState.addHandsFreeBackgroundTranscriptionJob(
      envelope: [0.1, 0.2], audioDuration: 1.0, estimatedRTF: 0.5)
    XCTAssertTrue(appState.isHandsFreeUtteranceFlushInProgress)

    appState.removeHandsFreeBackgroundTranscriptionJob(id: id)
    XCTAssertFalse(appState.isHandsFreeUtteranceFlushInProgress)
  }

  /// Regression guard: the flush-in-progress signal must NOT depend on `handsFreeSessionActive`,
  /// because `endHandsFreeSession` clears that flag first and then checks this property to decide
  /// whether it is safe to cancel the coordinator.
  func testFlushInProgressIndependentOfSessionActive() {
    let appState = AppState()
    appState.handsFreeSessionActive = false

    appState.beginHandsFreeIncrementalFlushBarrier()
    XCTAssertTrue(
      appState.isHandsFreeUtteranceFlushInProgress,
      "An in-flight flush must be detectable even after the session flag is cleared")

    appState.endHandsFreeIncrementalFlushBarrier()

    _ = appState.addHandsFreeBackgroundTranscriptionJob(
      envelope: [0.3], audioDuration: 0.8, estimatedRTF: 0.5)
    XCTAssertTrue(
      appState.isHandsFreeUtteranceFlushInProgress,
      "A pending background job must be detectable independent of the session flag")
  }
}
