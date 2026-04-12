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
}
