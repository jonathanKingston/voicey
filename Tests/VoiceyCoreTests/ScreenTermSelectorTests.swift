import XCTest

@testable import VoiceyCore

final class ScreenTermSelectorTests: XCTestCase {
  func testSelectKeepsManualGlossaryTerms() {
    let snapshot = ScreenContextSnapshot(
      queryText: "patient metformin",
      corpusChunks: ["toolbar cancel ok", "HbA1c lab result metformin"]
    )

    let terms = ScreenTermSelector.select(
      snapshot: snapshot,
      manualGlossary: "Voicey",
      manualGlossaryEnabled: true
    )

    XCTAssertTrue(terms.contains("Voicey"))
  }

  func testSelectRanksSnapshotTermsWithoutManualOutput() {
    let snapshot = ScreenContextSnapshot(
      queryText: "metformin dosage",
      corpusChunks: [
        "Patient metformin dosage increased",
        "File Edit View Help"
      ]
    )

    let terms = ScreenTermSelector.select(
      snapshot: snapshot,
      manualGlossary: "Voicey",
      manualGlossaryEnabled: false
    )

    XCTAssertTrue(terms.map { $0.lowercased() }.contains("metformin"))
    XCTAssertFalse(terms.contains("Voicey"))
  }

  func testDedupePreservesFirstCasing() {
    let terms = ScreenTermSelector.dedupePreservingOrder(
      ["Voicey", "voicey", "VOICEY", "Qwen"],
      maxCount: 10
    )
    XCTAssertEqual(terms, ["Voicey", "Qwen"])
  }
}
