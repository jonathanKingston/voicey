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

  func testAppendingInterUtteranceSpacingIfNeeded() {
    XCTAssertEqual(TextCleanup.appendingInterUtteranceSpacingIfNeeded("Hello."), "Hello. ")
    XCTAssertEqual(TextCleanup.appendingInterUtteranceSpacingIfNeeded("Hi "), "Hi ")
    XCTAssertEqual(TextCleanup.appendingInterUtteranceSpacingIfNeeded(""), "")
  }

  func testJoinHandsFreeUtterancesSeparatesWithSingleSpace() {
    XCTAssertEqual(
      TextCleanup.joinHandsFreeUtterances(["Hello, my name.", "Is.", "Jonathan."]),
      "Hello, my name. Is. Jonathan."
    )
  }

  func testJoinHandsFreeUtterancesTrimsAndDropsEmptyFragments() {
    XCTAssertEqual(
      TextCleanup.joinHandsFreeUtterances(["  Hello  ", "", "   ", "there"]),
      "Hello there"
    )
  }

  func testJoinHandsFreeUtterancesPreservesInternalLineBreaks() {
    XCTAssertEqual(
      TextCleanup.joinHandsFreeUtterances(["First\nline", "second"]),
      "First\nline second"
    )
  }

  func testJoinHandsFreeUtterancesEmptyInput() {
    XCTAssertEqual(TextCleanup.joinHandsFreeUtterances([]), "")
    XCTAssertEqual(TextCleanup.joinHandsFreeUtterances(["", "  "]), "")
  }

  private func defaultCustomReplacement(for phrase: String) -> String? {
    let command = VoiceCommand.defaults.first { $0.phrase == phrase }
    guard case .custom(let replacement) = command?.action else {
      return nil
    }
    return replacement
  }
}
