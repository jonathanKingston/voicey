import XCTest
@testable import VoiceyCore

final class TranscriptionRuntimeStateTests: XCTestCase {
  func testActiveStatesCoverLoadingRecordingAndProcessingOnly() {
    XCTAssertTrue(TranscriptionRuntimeState.loadingModel.isActive)
    XCTAssertTrue(TranscriptionRuntimeState.recording(startTime: Date()).isActive)
    XCTAssertTrue(TranscriptionRuntimeState.processing.isActive)
    XCTAssertFalse(TranscriptionRuntimeState.idle.isActive)
    XCTAssertFalse(TranscriptionRuntimeState.completed(text: "done").isActive)
    XCTAssertFalse(TranscriptionRuntimeState.error(message: "failed").isActive)
  }

  func testRecordingDurationOnlyAvailableForRecordingState() {
    let startTime = Date(timeIntervalSinceNow: -2)
    let recordingState = TranscriptionRuntimeState.recording(startTime: startTime)
    XCTAssertNotNil(recordingState.recordingDuration)
    XCTAssertNil(TranscriptionRuntimeState.idle.recordingDuration)
  }
}
