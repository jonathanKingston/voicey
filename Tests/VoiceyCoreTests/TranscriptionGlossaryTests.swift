import XCTest

@testable import VoiceyCore

final class TranscriptionGlossaryTests: XCTestCase {
  func testDecodingContextDisabledReturnsNil() {
    XCTAssertNil(TranscriptionGlossary.decodingContext(enabled: false, rawGlossary: "Metformin"))
  }

  func testDecodingContextEmptyGlossaryReturnsNil() {
    XCTAssertNil(TranscriptionGlossary.decodingContext(enabled: true, rawGlossary: "  \n  "))
  }

  func testFormatCommaSeparatedTerms() {
    XCTAssertEqual(
      TranscriptionGlossary.format("Metformin, HbA1c, nephropathy"),
      "Glossary: Metformin, HbA1c, nephropathy"
    )
  }

  func testFormatNewlineSeparatedTerms() {
    XCTAssertEqual(
      TranscriptionGlossary.format("QuirkQuid\nP3-Quattro\nO3-Omni"),
      "Glossary: QuirkQuid, P3-Quattro, O3-Omni"
    )
  }

  func testFormatTruncatesLongGlossary() {
    let longTerm = String(repeating: "a", count: TranscriptionGlossary.maxContextCharacterCount)
    let formatted = TranscriptionGlossary.format(longTerm)
    XCTAssertEqual(formatted.count, TranscriptionGlossary.maxContextCharacterCount)
    XCTAssertTrue(formatted.hasPrefix("Glossary: "))
  }
}
