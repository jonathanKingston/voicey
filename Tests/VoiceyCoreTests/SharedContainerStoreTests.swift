import Foundation
import XCTest
@testable import VoiceyCore

final class SharedContainerStoreTests: XCTestCase {
  private var temporaryDirectory: URL!

  override func setUpWithError() throws {
    try super.setUpWithError()
    temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("voicey-core-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: temporaryDirectory,
      withIntermediateDirectories: true
    )
  }

  override func tearDownWithError() throws {
    if FileManager.default.fileExists(atPath: temporaryDirectory.path) {
      try FileManager.default.removeItem(at: temporaryDirectory)
    }
    temporaryDirectory = nil
    try super.tearDownWithError()
  }

  func testSaveRequestRejectsConcurrentInFlightRequest() async throws {
    let store = try SharedContainerStore(baseDirectory: temporaryDirectory)
    let firstRequest = DictationRequest(requestID: "request-1", status: .pending)
    let secondRequest = DictationRequest(requestID: "request-2", status: .pending)

    try await store.saveRequest(firstRequest)

    do {
      try await store.saveRequest(secondRequest)
      XCTFail("Expected concurrent request save to fail")
    } catch let error as SharedContainerStoreError {
      if case .concurrentRequestNotAllowed = error {
        XCTAssertTrue(true)
      } else {
        XCTFail("Expected concurrentRequestNotAllowed, got \(error)")
      }
    } catch {
      XCTFail("Unexpected error type: \(error)")
    }
  }

  func testSaveRequestAllowsStatusUpdateForSameRequestID() async throws {
    let store = try SharedContainerStore(baseDirectory: temporaryDirectory)
    let pendingRequest = DictationRequest(requestID: "request-1", status: .pending)
    try await store.saveRequest(pendingRequest)

    let processingRequest = DictationRequest(
      requestID: "request-1",
      createdAt: pendingRequest.createdAt,
      source: pendingRequest.source,
      status: .processing
    )
    try await store.saveRequest(processingRequest)

    let stored = try await store.loadRequest()
    XCTAssertEqual(stored?.requestID, "request-1")
    XCTAssertEqual(stored?.status, .processing)
  }

  func testPurgeExpiredRequestMarksCancelled() async throws {
    let store = try SharedContainerStore(baseDirectory: temporaryDirectory)
    let oldDate = Date(timeIntervalSinceNow: -1000)
    let request = DictationRequest(
      requestID: "request-expired",
      createdAt: oldDate,
      source: "keyboard",
      status: .pending
    )
    try await store.saveRequest(request)

    try await store.purgeExpiredRequest(now: Date(), timeout: 60)
    let loaded = try await store.loadRequest()

    XCTAssertEqual(loaded?.status, .cancelled)
    XCTAssertEqual(loaded?.requestID, request.requestID)
  }

  func testMarkRequestProcessingTransitionsPendingToProcessing() async throws {
    let store = try SharedContainerStore(baseDirectory: temporaryDirectory)
    let request = DictationRequest(requestID: "request-1", status: .pending)
    try await store.saveRequest(request)

    try await store.markRequestProcessing(requestID: "request-1")
    let loaded = try await store.loadRequest()

    XCTAssertEqual(loaded?.status, .processing)
  }

  func testMarkRequestCompletedStoresCompletedRequestAndResult() async throws {
    let store = try SharedContainerStore(baseDirectory: temporaryDirectory)
    let request = DictationRequest(requestID: "request-2", status: .processing)
    try await store.saveRequest(request)

    try await store.markRequestCompleted(
      requestID: "request-2",
      text: "dictation done",
      language: "en",
      model: "qwen3-small"
    )

    let loadedRequest = try await store.loadRequest()
    let loadedResult = try await store.loadResult()

    XCTAssertEqual(loadedRequest?.status, .completed)
    XCTAssertEqual(loadedResult?.requestID, "request-2")
    XCTAssertEqual(loadedResult?.text, "dictation done")
    XCTAssertEqual(loadedResult?.error, nil)
  }

  func testMarkRequestFailedStoresErrorResultWithEmptyText() async throws {
    let store = try SharedContainerStore(baseDirectory: temporaryDirectory)
    let request = DictationRequest(requestID: "request-3", status: .processing)
    try await store.saveRequest(request)

    try await store.markRequestFailed(
      requestID: "request-3",
      errorMessage: "microphone unavailable"
    )

    let loadedRequest = try await store.loadRequest()
    let loadedResult = try await store.loadResult()

    XCTAssertEqual(loadedRequest?.status, .failed)
    XCTAssertEqual(loadedResult?.requestID, "request-3")
    XCTAssertEqual(loadedResult?.text, "")
    XCTAssertEqual(loadedResult?.error, "microphone unavailable")
  }

  func testMarkKeyboardProcessingPreservesLastInsertedRequest() async throws {
    let store = try SharedContainerStore(baseDirectory: temporaryDirectory)
    try await store.saveKeyboardState(
      KeyboardWorkflowState(
        isProcessing: false,
        lastSeenRequestID: "old-request",
        lastInsertedRequestID: "already-inserted"
      )
    )

    _ = try await store.markKeyboardProcessing(requestID: "new-request")
    let state = try await store.loadKeyboardState()

    XCTAssertEqual(state?.isProcessing, true)
    XCTAssertEqual(state?.lastSeenRequestID, "new-request")
    XCTAssertEqual(state?.lastInsertedRequestID, "already-inserted")
  }

  func testMarkKeyboardInsertedSetsInsertedAndIdleState() async throws {
    let store = try SharedContainerStore(baseDirectory: temporaryDirectory)

    _ = try await store.markKeyboardInserted(requestID: "request-99")
    let state = try await store.loadKeyboardState()

    XCTAssertEqual(state?.isProcessing, false)
    XCTAssertEqual(state?.lastSeenRequestID, "request-99")
    XCTAssertEqual(state?.lastInsertedRequestID, "request-99")
  }

  func testMarkKeyboardIdlePreservesLastInsertedRequest() async throws {
    let store = try SharedContainerStore(baseDirectory: temporaryDirectory)
    try await store.saveKeyboardState(
      KeyboardWorkflowState(
        isProcessing: true,
        lastSeenRequestID: "request-11",
        lastInsertedRequestID: "request-10"
      )
    )

    _ = try await store.markKeyboardIdle(lastSeenRequestID: "request-11")
    let state = try await store.loadKeyboardState()

    XCTAssertEqual(state?.isProcessing, false)
    XCTAssertEqual(state?.lastSeenRequestID, "request-11")
    XCTAssertEqual(state?.lastInsertedRequestID, "request-10")
  }

  func testMarkRequestProcessingRejectsTransitionFromCompleted() async throws {
    let store = try SharedContainerStore(baseDirectory: temporaryDirectory)
    let request = DictationRequest(requestID: "request-completed", status: .completed)
    try await store.saveRequest(request)

    do {
      _ = try await store.markRequestProcessing(requestID: "request-completed")
      XCTFail("Expected invalid transition error")
    } catch let error as SharedContainerStoreError {
      switch error {
      case .invalidRequestTransition(let from, let to):
        XCTAssertEqual(from, .completed)
        XCTAssertEqual(to, .processing)
      default:
        XCTFail("Expected invalidRequestTransition, got \(error)")
      }
    } catch {
      XCTFail("Unexpected error type: \(error)")
    }
  }
}
