import XCTest

@testable import VoiceyCore

final class BM25Tests: XCTestCase {
  func testRankTermsPrefersRelevantDocument() {
    let ranked = BM25.rankTerms(
      query: "metformin dosage patient",
      documents: [
        "Patient chart metformin dosage adjustment",
        "File Edit View Help Window",
        "Unrelated toolbar labels cancel ok",
      ]
    )

    let topTerms = ranked.prefix(5).map(\.term).map { $0.lowercased() }
    XCTAssertTrue(ranked.contains { $0.term.lowercased() == "metformin" })
    XCTAssertFalse(topTerms.contains("cancel"))
  }
}
