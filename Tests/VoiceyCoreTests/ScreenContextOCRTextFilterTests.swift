import VoiceyCore
import XCTest

final class ScreenContextOCRTextFilterTests: XCTestCase {
  func testFiltersLogLinesAndDates() {
    let lines = [
      "2026-05-27 18:38:53 Steering: manual=0 screen=48",
      "I gave it a go. Can you look at your logs?",
      "ScreenContextOCR: lines=86 queryChars=349"
    ]
    let filtered = ScreenContextOCRTextFilter.filteredRecognizedLines(lines)
    XCTAssertEqual(filtered, ["I gave it a go. Can you look at your logs?"])
  }

  func testSteeringNoiseTokenRejectsNumbersAndPIDs() {
    XCTAssertTrue(ScreenContextOCRTextFilter.isSteeringNoiseToken("44"))
    XCTAssertTrue(ScreenContextOCRTextFilter.isSteeringNoiseToken("52050"))
    XCTAssertTrue(ScreenContextOCRTextFilter.isSteeringNoiseToken("Voicey149614"))
    XCTAssertTrue(ScreenContextOCRTextFilter.isSteeringNoiseToken("a24d2d"))
    XCTAssertTrue(ScreenContextOCRTextFilter.isSteeringNoiseToken("st"))
    XCTAssertFalse(ScreenContextOCRTextFilter.isSteeringNoiseToken("search-mcp"))
  }
}
