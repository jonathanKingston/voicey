import XCTest
@testable import VoiceyCore

final class KeyboardWorkflowResolverTests: XCTestCase {
  func testStatusDisplaysEnableFullAccessWhenRequired() {
    let status = KeyboardWorkflowResolver.resolve(
      hasFullAccess: false,
      request: nil,
      result: nil,
      keyboardState: nil
    )

    XCTAssertEqual(status.statusMessage, "Enable Full Access in Settings")
    XCTAssertEqual(status.canRequestDictation, false)
    XCTAssertEqual(status.canInsertLatest, false)
  }

  func testStatusDisplaysRequestStateDuringPendingRequest() {
    let request = DictationRequest(requestID: "r1", status: .pending)
    let status = KeyboardWorkflowResolver.resolve(
      hasFullAccess: true,
      request: request,
      result: nil,
      keyboardState: nil
    )

    XCTAssertEqual(status.statusMessage, "Request pending")
    XCTAssertEqual(status.canRequestDictation, false)
    XCTAssertEqual(status.canInsertLatest, false)
  }

  func testStatusDisplaysResultReadyWhenInsertableResultExists() {
    let request = DictationRequest(requestID: "r1", status: .completed)
    let result = DictationResult(requestID: "r1", text: "hello world")
    let keyboardState = KeyboardWorkflowState(
      isProcessing: false,
      lastSeenRequestID: "r1",
      lastInsertedRequestID: nil
    )

    let status = KeyboardWorkflowResolver.resolve(
      hasFullAccess: true,
      request: request,
      result: result,
      keyboardState: keyboardState
    )

    XCTAssertEqual(status.statusMessage, "Result ready")
    XCTAssertEqual(status.canRequestDictation, true)
    XCTAssertEqual(status.canInsertLatest, true)
  }

  func testStatusDisplaysStaleResultWhenLastSeenDiffers() {
    let request = DictationRequest(requestID: "r1", status: .completed)
    let result = DictationResult(requestID: "r0", text: "old")
    let keyboardState = KeyboardWorkflowState(
      isProcessing: false,
      lastSeenRequestID: "r1",
      lastInsertedRequestID: nil
    )

    let status = KeyboardWorkflowResolver.resolve(
      hasFullAccess: true,
      request: request,
      result: result,
      keyboardState: keyboardState
    )

    XCTAssertEqual(status.statusMessage, "Stale result available")
    XCTAssertEqual(status.canRequestDictation, true)
    XCTAssertEqual(status.canInsertLatest, false)
  }

  func testStatusDisplaysInsertedStateWhenAlreadyInserted() {
    let request = DictationRequest(requestID: "r1", status: .completed)
    let result = DictationResult(requestID: "r1", text: "hello world")
    let keyboardState = KeyboardWorkflowState(
      isProcessing: false,
      lastSeenRequestID: "r1",
      lastInsertedRequestID: "r1"
    )

    let status = KeyboardWorkflowResolver.resolve(
      hasFullAccess: true,
      request: request,
      result: result,
      keyboardState: keyboardState
    )

    XCTAssertEqual(status.statusMessage, "Transcript inserted")
    XCTAssertEqual(status.canRequestDictation, true)
    XCTAssertEqual(status.canInsertLatest, false)
  }
}
