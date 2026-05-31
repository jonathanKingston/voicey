import XCTest

@testable import VoiceyCore

/// Regression guard for incremental transcription: screen-context snapshots must be reusable
/// across pause-separated chunks in one recording session (see issue exploration in PR #110).
final class SteeringContextSessionReuseTests: XCTestCase {
  private let sessionSnapshot = ScreenContextSnapshot(
    queryText: "metformin dosage",
    corpusChunks: [
      "Patient metformin dosage increased",
      "File Edit View Help"
    ]
  )

  private func buildScreenContextSteering(snapshot: ScreenContextSnapshot?) -> SteeringContextBuilder.Output {
    SteeringContextBuilder.build(
      SteeringContextBuilder.Input(
        manualGlossaryEnabled: false,
        manualGlossary: "",
        screenContextEnabled: true,
        snapshot: snapshot
      )
    )
  }

  func testSameSnapshotProducesScreenTermsForEveryChunk() {
    let first = buildScreenContextSteering(snapshot: sessionSnapshot)
    let second = buildScreenContextSteering(snapshot: sessionSnapshot)

    XCTAssertFalse(first.terms.isEmpty)
    XCTAssertEqual(first.terms, second.terms)
    XCTAssertEqual(first.decoderContext, second.decoderContext)
  }

  func testNilSnapshotAfterClearProducesNoScreenDerivedTerms() {
    let output = buildScreenContextSteering(snapshot: nil)

    XCTAssertTrue(output.terms.isEmpty)
    XCTAssertFalse(output.decoderContext?.contains("metformin") ?? false)
  }
}
