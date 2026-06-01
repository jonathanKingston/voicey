import XCTest

@testable import VoiceyCore

final class ModelSessionLifecyclePolicyTests: XCTestCase {
  func testBlocksRecordingOnlyDuringEngineSwitch() {
    let policy = ModelSessionLifecyclePolicy(
      isModelEngineSwitchInProgress: true,
      isTranscriptionSessionBusy: false
    )
    XCTAssertTrue(policy.blocksRecordingStart)
    XCTAssertTrue(policy.blocksModelEngineReconfiguration)
  }

  func testBusySessionBlocksModelReconfigurationNotRecording() {
    let policy = ModelSessionLifecyclePolicy(
      isModelEngineSwitchInProgress: false,
      isTranscriptionSessionBusy: true
    )
    XCTAssertFalse(policy.blocksRecordingStart)
    XCTAssertTrue(policy.blocksModelEngineReconfiguration)
  }

  func testIdleSessionAllowsBoth() {
    let policy = ModelSessionLifecyclePolicy(
      isModelEngineSwitchInProgress: false,
      isTranscriptionSessionBusy: false
    )
    XCTAssertFalse(policy.blocksRecordingStart)
    XCTAssertFalse(policy.blocksModelEngineReconfiguration)
  }
}
