import XCTest
@testable import VoiceyCore

final class DictationRouteTests: XCTestCase {
  func testParseReturnsStartRouteForValidDictationStartURL() {
    let url = URL(string: "voicey://dictation/start")!
    XCTAssertEqual(DictationRoute.parse(url: url), .startDictation)
  }

  func testParseReturnsNilForUnexpectedScheme() {
    let url = URL(string: "voicey-dev://dictation/start")!
    XCTAssertNil(DictationRoute.parse(url: url))
  }

  func testParseReturnsNilForUnexpectedHost() {
    let url = URL(string: "voicey://settings/start")!
    XCTAssertNil(DictationRoute.parse(url: url))
  }

  func testParseReturnsNilForUnexpectedPath() {
    let url = URL(string: "voicey://dictation/finish")!
    XCTAssertNil(DictationRoute.parse(url: url))
  }
}
