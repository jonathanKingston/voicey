import XCTest
@testable import VoiceyCore

final class SpeechBackendKindTests: XCTestCase {
  func testAllCasesContainSupportedBackends() {
    XCTAssertEqual(
      Set(SpeechBackendKind.allCases),
      Set([.whisperKit, .granitePython, .qwenMLX])
    )
  }
}
