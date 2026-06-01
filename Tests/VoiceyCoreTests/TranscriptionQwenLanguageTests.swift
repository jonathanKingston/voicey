import XCTest

@testable import VoiceyCore

final class TranscriptionQwenLanguageTests: XCTestCase {
  func testAutoReturnsNilParameter() {
    XCTAssertNil(
      TranscriptionQwenLanguage.qwenLanguageParameter(
        storedID: TranscriptionQwenLanguage.autoOption.id
      )
    )
  }

  func testEnglishReturnsQwenName() {
    XCTAssertEqual(
      TranscriptionQwenLanguage.qwenLanguageParameter(storedID: "english"),
      "English"
    )
  }

  func testUnknownStoredIDFallsBackToAuto() {
    XCTAssertEqual(
      TranscriptionQwenLanguage.normalizedStoredID("not_a_language"),
      TranscriptionQwenLanguage.autoOption.id
    )
  }

  func testSupportedOptionsIncludeAutoAndEnglish() {
    XCTAssertEqual(TranscriptionQwenLanguage.supportedOptions.first?.id, "auto")
    XCTAssertTrue(
      TranscriptionQwenLanguage.supportedOptions.contains {
        $0.qwenLanguageName == "English"
      }
    )
  }
}
