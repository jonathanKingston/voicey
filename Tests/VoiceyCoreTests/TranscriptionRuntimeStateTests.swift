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

  func testModelRuntimeStatusReadinessFlags() {
    XCTAssertFalse(ModelRuntimeStatus.notDownloaded.isReady)
    XCTAssertFalse(ModelRuntimeStatus.loading.isReady)
    XCTAssertTrue(ModelRuntimeStatus.ready.isReady)
    XCTAssertFalse(ModelRuntimeStatus.failed("x").isReady)

    XCTAssertFalse(ModelRuntimeStatus.notDownloaded.isLoading)
    XCTAssertTrue(ModelRuntimeStatus.loading.isLoading)
    XCTAssertFalse(ModelRuntimeStatus.ready.isLoading)
    XCTAssertFalse(ModelRuntimeStatus.failed("x").isLoading)
  }
}
