import XCTest

@testable import VoiceyCore

final class UtteranceTranscriptionFinishPolicyTests: XCTestCase {
  func testManualSharedBufferWithoutIncrementalUsesPCM() {
    let route = UtteranceTranscriptionFinishPolicy.route(isSharedBuffer: true)
    XCTAssertEqual(route, .sharedPCMHandle)
    XCTAssertTrue(
      UtteranceTranscriptionFinishPolicy.shouldFinishViaSharedPCMTranscription(
        route: route,
        hasBufferedIncrementalAudio: false,
        handsFreeUtterance: false))
    XCTAssertFalse(
      UtteranceTranscriptionFinishPolicy.shouldFinishViaIncrementalFlush(
        route: route,
        hasBufferedIncrementalAudio: false,
        handsFreeUtterance: false))
  }

  func testManualSharedBufferWithIncrementalUsesFlush() {
    let route = UtteranceTranscriptionFinishPolicy.route(isSharedBuffer: true)
    XCTAssertTrue(
      UtteranceTranscriptionFinishPolicy.shouldFinishViaIncrementalFlush(
        route: route,
        hasBufferedIncrementalAudio: true,
        handsFreeUtterance: false))
    XCTAssertFalse(
      UtteranceTranscriptionFinishPolicy.shouldFinishViaSharedPCMTranscription(
        route: route,
        hasBufferedIncrementalAudio: true,
        handsFreeUtterance: false))
  }

  func testHandsFreeSharedBufferAlwaysUsesPCMEvenWithIncremental() {
    let route = UtteranceTranscriptionFinishPolicy.route(isSharedBuffer: true)
    XCTAssertTrue(
      UtteranceTranscriptionFinishPolicy.shouldFinishViaSharedPCMTranscription(
        route: route,
        hasBufferedIncrementalAudio: true,
        handsFreeUtterance: true),
      "#163: drained hands-free PCM is authoritative; incremental is partials only")
    XCTAssertFalse(
      UtteranceTranscriptionFinishPolicy.shouldFinishViaIncrementalFlush(
        route: route,
        hasBufferedIncrementalAudio: true,
        handsFreeUtterance: true))
  }

  func testInMemoryAlwaysUsesIncrementalFlush() {
    let route = UtteranceTranscriptionFinishPolicy.route(isSharedBuffer: false)
    XCTAssertEqual(route, .incrementalCoordinatorFlush)
    XCTAssertTrue(
      UtteranceTranscriptionFinishPolicy.shouldFinishViaIncrementalFlush(
        route: route,
        hasBufferedIncrementalAudio: false,
        handsFreeUtterance: false))
    XCTAssertTrue(
      UtteranceTranscriptionFinishPolicy.shouldFinishViaIncrementalFlush(
        route: route,
        hasBufferedIncrementalAudio: true,
        handsFreeUtterance: true))
  }
}
