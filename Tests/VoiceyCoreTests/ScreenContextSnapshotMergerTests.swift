import VoiceyCore
import XCTest

final class ScreenContextSnapshotMergerTests: XCTestCase {
  func testMergingPrefersBaseQueryAndDedupesChunks() {
    let base = ScreenContextSnapshot(queryText: "", corpusChunks: ["Alpha term"])
    let supplemental = ScreenContextSnapshot(
      queryText: "OCR query line",
      corpusChunks: ["Alpha term", "Beta from OCR"]
    )

    let merged = ScreenContextSnapshotMerger.merging(base, supplemental: supplemental)
    XCTAssertEqual(merged.queryText, "OCR query line")
    XCTAssertEqual(merged.corpusChunks, ["Alpha term", "Beta from OCR"])
  }

  func testMergingKeepsBaseQueryWhenPresent() {
    let base = ScreenContextSnapshot(queryText: "Focused field", corpusChunks: [])
    let supplemental = ScreenContextSnapshot(queryText: "OCR only", corpusChunks: ["Chunk"])

    let merged = ScreenContextSnapshotMerger.merging(base, supplemental: supplemental)
    XCTAssertEqual(merged.queryText, "Focused field")
    XCTAssertEqual(merged.corpusChunks, ["Chunk"])
  }
}
