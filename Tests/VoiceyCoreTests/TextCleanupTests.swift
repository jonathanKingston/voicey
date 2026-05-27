import XCTest

@testable import VoiceyCore

final class TextCleanupTests: XCTestCase {
  func testDefaultTextCleanupDoesNotRewriteVoiceCommandDefaults() {
    let text = """
      that is for example versus mister missus doctor okay etcetera et cetera
      """

    XCTAssertEqual(
      TextCleanup.applyExpansions(text, expansions: TextCleanup.defaultTextExpansions),
      text
    )
  }

  func testDefaultExpansionsNormalizeSpelledOutOK() {
    XCTAssertEqual(
      TextCleanup.applyExpansions(
        "that sounds o k to me", expansions: TextCleanup.defaultTextExpansions),
      "that sounds OK to me"
    )
  }

  func testDefaultVoiceCommandsIncludeOptionalTextExpansions() {
    XCTAssertEqual(defaultCustomReplacement(for: "etcetera"), "etc.")
    XCTAssertEqual(defaultCustomReplacement(for: "et cetera"), "etc.")
    XCTAssertEqual(defaultCustomReplacement(for: "for example"), "e.g.")
    XCTAssertEqual(defaultCustomReplacement(for: "versus"), "vs.")
    XCTAssertEqual(defaultCustomReplacement(for: "mister"), "Mr.")
    XCTAssertEqual(defaultCustomReplacement(for: "missus"), "Mrs.")
    XCTAssertEqual(defaultCustomReplacement(for: "doctor"), "Dr.")
    XCTAssertEqual(defaultCustomReplacement(for: "okay"), "OK")
  }

  func testDefaultVoiceCommandsDoNotIncludeThatIsExpansion() {
    XCTAssertNil(defaultCustomReplacement(for: "that is"))
  }

  private func defaultCustomReplacement(for phrase: String) -> String? {
    let command = VoiceCommand.defaults.first { $0.phrase == phrase }
    guard case .custom(let replacement) = command?.action else {
      return nil
    }
    return replacement
  }
}
