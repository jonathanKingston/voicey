@testable import Voicey
import XCTest

/// Locks in #129: Rust `voicey-capture` utterances use shared PCM handles and must not
/// complete transcription via an empty incremental `flushAndFinish` only.
final class UtteranceTranscriptionFinishTests: XCTestCase {
  func testSharedBufferRoutesToPCMHandleTranscription() {
    let handle = PCMBufferHandle(shmName: "voicey_pcm_test", sampleCount: 16_000, sampleRate: 16_000)
    let captured = CapturedAudio.sharedBuffer(handle)
    XCTAssertEqual(
      UtteranceTranscriptionFinish.route(for: captured),
      .sharedPCMHandle)
    XCTAssertTrue(captured.finishesViaSharedPCMHandleTranscription)
  }

  func testInMemoryRoutesToIncrementalCoordinatorFlush() {
    let captured = CapturedAudio.inMemory([0.1, 0.2, 0.3])
    XCTAssertEqual(
      UtteranceTranscriptionFinish.route(for: captured),
      .incrementalCoordinatorFlush)
    XCTAssertFalse(captured.finishesViaSharedPCMHandleTranscription)
  }
}
