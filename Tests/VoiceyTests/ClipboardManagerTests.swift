import AppKit
import XCTest
@testable import Voicey

/// Regression tests for ClipboardManager capture/restore.
///
/// These run against `NSPasteboard.general` because ClipboardManager.shared is bound
/// to it. Each test snapshots the real pasteboard contents and restores them on
/// teardown so local runs leave the user's clipboard untouched.
final class ClipboardManagerTests: XCTestCase {
  private var originalSnapshot: [[(NSPasteboard.PasteboardType, Data)]] = []
  private let pasteboard = NSPasteboard.general

  override func setUp() {
    super.setUp()
    originalSnapshot = snapshotPasteboard()
  }

  override func tearDown() {
    restorePasteboard(originalSnapshot)
    super.tearDown()
  }

  // Empty-pasteboard capture used to round-trip as a no-op restore, leaving the
  // transcription stuck on the clipboard. Restoring an empty snapshot must now
  // actually clear the pasteboard.
  func testRestoringEmptySnapshotClearsClipboard() {
    pasteboard.clearContents()
    let snapshot = ClipboardManager.shared.captureContents()
    XCTAssertTrue(snapshot.isEmpty, "Empty pasteboard should produce an empty snapshot")

    pasteboard.clearContents()
    pasteboard.setString("transcription text", forType: .string)
    XCTAssertEqual(pasteboard.string(forType: .string), "transcription text")

    ClipboardManager.shared.restoreContents(snapshot)

    XCTAssertNil(
      pasteboard.string(forType: .string),
      "Restoring an empty snapshot must clear the clipboard, not leave the transcription behind"
    )
  }

  // The legacy capture path (pasteboard.types + data(forType:)) flattens multi-item
  // pasteboards into a single item, so only the first item survived restore.
  func testRoundTripPreservesMultipleItems() {
    pasteboard.clearContents()
    let firstItem = NSPasteboardItem()
    firstItem.setString("first", forType: .string)
    let secondItem = NSPasteboardItem()
    secondItem.setString("second", forType: .string)
    XCTAssertTrue(pasteboard.writeObjects([firstItem, secondItem]))

    let snapshot = ClipboardManager.shared.captureContents()
    XCTAssertEqual(snapshot.count, 2, "Multi-item pasteboard should round-trip with 2 items")

    pasteboard.clearContents()
    pasteboard.setString("transcription", forType: .string)

    ClipboardManager.shared.restoreContents(snapshot)

    guard let restored = pasteboard.pasteboardItems else {
      return XCTFail("Pasteboard should expose restored items")
    }
    XCTAssertEqual(restored.count, 2)
    XCTAssertEqual(restored[0].string(forType: .string), "first")
    XCTAssertEqual(restored[1].string(forType: .string), "second")
  }

  func testRoundTripPreservesSingleString() {
    pasteboard.clearContents()
    pasteboard.setString("hello", forType: .string)

    let snapshot = ClipboardManager.shared.captureContents()
    XCTAssertEqual(snapshot.count, 1)

    pasteboard.clearContents()
    pasteboard.setString("transcription", forType: .string)

    ClipboardManager.shared.restoreContents(snapshot)

    XCTAssertEqual(pasteboard.string(forType: .string), "hello")
  }

  // MARK: - Helpers

  private func snapshotPasteboard() -> [[(NSPasteboard.PasteboardType, Data)]] {
    guard let items = pasteboard.pasteboardItems else { return [] }
    return items.map { item in
      item.types.compactMap { type -> (NSPasteboard.PasteboardType, Data)? in
        guard let data = item.data(forType: type) else { return nil }
        return (type, data)
      }
    }
  }

  private func restorePasteboard(_ snapshot: [[(NSPasteboard.PasteboardType, Data)]]) {
    pasteboard.clearContents()
    guard !snapshot.isEmpty else { return }
    let items = snapshot.map { typeDataPairs -> NSPasteboardItem in
      let item = NSPasteboardItem()
      for (type, data) in typeDataPairs {
        item.setData(data, forType: type)
      }
      return item
    }
    _ = pasteboard.writeObjects(items)
  }
}
