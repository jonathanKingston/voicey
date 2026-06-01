import XCTest

@testable import VoiceyCore

final class TranscriptionSessionModelPinTests: XCTestCase {
  func testResolvedUsesFallbackWhenUnpinned() {
    let pin = TranscriptionSessionModelPin<String>()
    XCTAssertEqual(pin.resolved(fallback: "qwen"), "qwen")
  }

  func testResolvedUsesPinnedModel() {
    var pin = TranscriptionSessionModelPin<String>()
    pin.pin("granite")
    XCTAssertEqual(pin.resolved(fallback: "qwen"), "granite")
  }

  func testClearRestoresFallback() {
    var pin = TranscriptionSessionModelPin<String>()
    pin.pin("granite")
    pin.clear()
    XCTAssertNil(pin.pinned)
    XCTAssertEqual(pin.resolved(fallback: "qwen"), "qwen")
  }

  func testRePinUpdatesModel() {
    var pin = TranscriptionSessionModelPin<String>()
    pin.pin("first")
    pin.pin("second")
    XCTAssertEqual(pin.resolved(fallback: "fallback"), "second")
  }
}
