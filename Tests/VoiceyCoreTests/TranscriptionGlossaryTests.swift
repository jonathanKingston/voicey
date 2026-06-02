import XCTest

@testable import VoiceyCore

final class TranscriptionGlossaryTests: XCTestCase {
  func testDecodingContextDisabledReturnsNil() {
    XCTAssertNil(TranscriptionGlossary.decodingContext(enabled: false, rawGlossary: "Metformin"))
  }

  func testDecodingContextEmptyGlossaryReturnsNil() {
    XCTAssertEqual(
      TranscriptionGlossary.decodingContext(enabled: true, rawGlossary: "  \n  "),
      "Glossary: Voicey"
    )
  }

  func testDecodingContextAlwaysIncludesBuiltInVoicey() {
    XCTAssertEqual(
      TranscriptionGlossary.decodingContext(terms: ["Metformin"]),
      "Glossary: Voicey, Metformin"
    )
  }

  func testDecodingContextMergesManualAndScreenTerms() {
    let context = TranscriptionGlossary.decodingContext(
      terms: ["Voicey", "metformin", "Voicey"]
    )
    XCTAssertEqual(context, "Glossary: Voicey, metformin")
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
