import VoiceyCore
import XCTest

final class ScreenTermHealingTests: XCTestCase {
  func testMergedAdjacentTokensRejoinsSplitWord() {
    let merged = ScreenTermHealing.mergedAdjacentTokens(in: "log st,ream here")
    XCTAssertTrue(merged.contains("stream"))
  }

  func testMergedAdjacentTokensIgnoresSpaceSeparatedPieces() {
    let merged = ScreenTermHealing.mergedAdjacentTokens(in: "log st ream here")
    XCTAssertFalse(merged.contains("stream"))
    XCTAssertFalse(merged.contains("logstream"))
  }

  func testAppearsWithWordBoundariesRejectsGluedSubstring() {
    XCTAssertFalse(ScreenTermFilter.appearsWithWordBoundaries("stream", in: "log st ream"))
    XCTAssertTrue(ScreenTermFilter.appearsWithWordBoundaries("stream", in: "watch stream live"))
  }

  func testDateTokensAreNoise() {
    XCTAssertTrue(ScreenTermFilter.isSteeringNoiseToken("2026-05-27"))
    XCTAssertTrue(ScreenTermFilter.isSteeringNoiseToken("18:44:54"))
  }

  func testAnchorCompletionFixesMissingPrefix() {
    let anchors = ["transcription", "Voicey"]
    XCTAssertEqual(
      ScreenTermHealing.anchorCompletion(for: "ranscription", anchors: anchors), "transcription")
  }

  func testInteriorFragmentDropped() {
    let anchors = ["transcription"]
    XCTAssertTrue(ScreenTermHealing.isInteriorFragment("script", anchors: anchors))
    XCTAssertFalse(ScreenTermHealing.isInteriorFragment("ranscription", anchors: anchors))
  }

  func testJoinContinuationLinesMergesLowercaseFollowOn() {
    let lines = [
      "I gave it a go. Can you look at your",
      "logs?"
    ]
    let joined = ScreenContextOCRTextFilter.joinContinuationLines(lines)
    XCTAssertEqual(joined, ["I gave it a go. Can you look at your logs?"])
  }
}
