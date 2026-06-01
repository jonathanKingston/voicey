import XCTest

@testable import VoiceyCore

final class TranscriptionSessionBusySignalsTests: XCTestCase {
  func testRecordingActiveBlocksModelReconfiguration() {
    let signals = TranscriptionSessionBusySignals(
      transcriptionStateIsActive: true,
      handsFreeSessionActive: false,
      handsFreeUtteranceFlushInProgress: false
    )
    XCTAssertTrue(signals.isTranscriptionSessionBusy)
  }

  func testHandsFreeSessionBlocksModelReconfigurationWhileIdle() {
    let signals = TranscriptionSessionBusySignals(
      transcriptionStateIsActive: false,
      handsFreeSessionActive: true,
      handsFreeUtteranceFlushInProgress: false
    )
    XCTAssertTrue(signals.isTranscriptionSessionBusy)
  }

  func testHandsFreeFlushBlocksModelReconfigurationWhileIdle() {
    let signals = TranscriptionSessionBusySignals(
      transcriptionStateIsActive: false,
      handsFreeSessionActive: false,
      handsFreeUtteranceFlushInProgress: true
    )
    XCTAssertTrue(signals.isTranscriptionSessionBusy)
  }

  func testIdleHotkeySessionAllowsModelReconfiguration() {
    let signals = TranscriptionSessionBusySignals(
      transcriptionStateIsActive: false,
      handsFreeSessionActive: false,
      handsFreeUtteranceFlushInProgress: false
    )
    XCTAssertFalse(signals.isTranscriptionSessionBusy)
  }

  func testBusySessionDefersModelEngineSwitchButNotRecordingStart() {
    let policy = TranscriptionSessionBusySignals(
      transcriptionStateIsActive: true,
      handsFreeSessionActive: false,
      handsFreeUtteranceFlushInProgress: false
    ).modelSessionLifecyclePolicy(isModelEngineSwitchInProgress: false)

    XCTAssertFalse(policy.blocksRecordingStart)
    XCTAssertTrue(policy.blocksModelEngineReconfiguration)
  }

  func testEngineSwitchBlocksRecordingStart() {
    let policy = TranscriptionSessionBusySignals(
      transcriptionStateIsActive: false,
      handsFreeSessionActive: false,
      handsFreeUtteranceFlushInProgress: false
    ).modelSessionLifecyclePolicy(isModelEngineSwitchInProgress: true)

    XCTAssertTrue(policy.blocksRecordingStart)
    XCTAssertTrue(policy.blocksModelEngineReconfiguration)
  }

  func testPinnedModelSurvivesSettingsChangeDuringRecording() {
    var pin = TranscriptionSessionModelPin<String>()
    pin.pin("utterance-model")

    let resolvedWhileBusy = pin.resolved(fallback: "settings-changed")
    XCTAssertEqual(resolvedWhileBusy, "utterance-model")
  }
}
