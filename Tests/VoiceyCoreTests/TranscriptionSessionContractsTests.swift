import XCTest
@testable import VoiceyCore

final class TranscriptionSessionContractsTests: XCTestCase {
  func testActiveStatesMatchRecordingAndProcessingOnly() {
    XCTAssertFalse(TranscriptionSessionState.idle.isActive)
    XCTAssertTrue(TranscriptionSessionState.recording(startedAt: Date()).isActive)
    XCTAssertTrue(TranscriptionSessionState.processing(requestID: "req-1").isActive)
    XCTAssertFalse(
      TranscriptionSessionState.completed(
        text: "hello",
        metadata: TranscriptionSessionMetadata()
      ).isActive
    )
    XCTAssertFalse(TranscriptionSessionState.failed(message: "error").isActive)
  }

  func testReducerMovesIdleToRecordingAndProcessingToCompleted() throws {
    let recording = try TranscriptionSessionReducer.reduce(
      .idle,
      event: .startRecording(startedAt: Date(timeIntervalSince1970: 1))
    )
    guard case .recording = recording else {
      XCTFail("Expected recording state")
      return
    }

    let processing = try TranscriptionSessionReducer.reduce(
      recording,
      event: .startProcessing(requestID: "request-1")
    )
    guard case .processing(let requestID) = processing else {
      XCTFail("Expected processing state")
      return
    }
    XCTAssertEqual(requestID, "request-1")

    let completed = try TranscriptionSessionReducer.reduce(
      processing,
      event: .complete(
        text: "hello",
        metadata: TranscriptionSessionMetadata(language: "en", modelIdentifier: "model")
      )
    )
    guard case .completed(let text, _) = completed else {
      XCTFail("Expected completed state")
      return
    }
    XCTAssertEqual(text, "hello")
  }

  func testReducerRejectsInvalidIdleToCompletedTransition() {
    XCTAssertThrowsError(
      try TranscriptionSessionReducer.reduce(
        .idle,
        event: .complete(text: "hello", metadata: TranscriptionSessionMetadata())
      )
    ) { error in
      guard let transitionError = error as? TranscriptionSessionTransitionError else {
        XCTFail("Unexpected error type: \(error)")
        return
      }

      switch transitionError {
      case .invalidTransition:
        XCTAssertTrue(true)
      default:
        XCTFail("Expected invalidTransition, got \(transitionError)")
      }
    }
  }

  func testReducerRejectsEmptyCompletedText() {
    XCTAssertThrowsError(
      try TranscriptionSessionReducer.reduce(
        .processing(requestID: "request-1"),
        event: .complete(text: "   ", metadata: TranscriptionSessionMetadata())
      )
    ) { error in
      guard let transitionError = error as? TranscriptionSessionTransitionError else {
        XCTFail("Unexpected error type: \(error)")
        return
      }

      switch transitionError {
      case .emptyCompletedText:
        XCTAssertTrue(true)
      default:
        XCTFail("Expected emptyCompletedText, got \(transitionError)")
      }
    }
  }

  func testReducerCancelAlwaysResetsToIdle() throws {
    let state = try TranscriptionSessionReducer.reduce(
      .processing(requestID: "request-2"),
      event: .cancel
    )
    XCTAssertEqual(state, .idle)
  }
}
