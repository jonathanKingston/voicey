@testable import Voicey
import VoiceyCore
import XCTest

final class ScreenContextStoreTests: XCTestCase {
  private let store = ScreenContextStore.shared

  override func tearDown() {
    store.clear()
    super.tearDown()
  }

  func testCurrentSnapshotDoesNotClearStore() {
    let snapshot = ScreenContextSnapshot(
      queryText: "Voicey Composer",
      corpusChunks: ["Cursor Composer panel"]
    )
    store.set(snapshot)

    XCTAssertEqual(store.currentSnapshot(), snapshot)
    XCTAssertEqual(store.currentSnapshot(), snapshot)
  }

  func testConsumeSnapshotClearsStore() {
    let snapshot = ScreenContextSnapshot(
      queryText: "Voicey Composer",
      corpusChunks: ["Cursor Composer panel"]
    )
    store.set(snapshot)

    XCTAssertEqual(store.consumeSnapshot(), snapshot)
    XCTAssertNil(store.currentSnapshot())
  }

  func testClearRemovesSnapshot() {
    store.set(ScreenContextSnapshot(queryText: "term", corpusChunks: ["term"]))
    store.clear()
    XCTAssertNil(store.currentSnapshot())
  }

  func testStaleCaptureCannotOverwriteNewSessionSnapshot() {
    let staleToken = store.beginCaptureSession()
    let currentToken = store.beginCaptureSession()

    store.set(
      ScreenContextSnapshot(queryText: "stale", corpusChunks: ["stale"]),
      sessionToken: staleToken
    )
    store.set(
      ScreenContextSnapshot(queryText: "current", corpusChunks: ["current"]),
      sessionToken: currentToken
    )

    XCTAssertEqual(store.currentSnapshot()?.queryText, "current")
  }
}
