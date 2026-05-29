import AppKit
import os

/// Manages clipboard operations
final class ClipboardManager: @unchecked Sendable {
  static let shared = ClipboardManager()

  private let pasteboard = NSPasteboard.general

  /// Stored clipboard data for restore (legacy single-flight save)
  private var savedItems: SavedClipboardSnapshot?

  /// One pasteboard item represented as its type/data pairs.
  typealias SavedClipboardItem = [(NSPasteboard.PasteboardType, Data)]
  /// Full pasteboard snapshot preserving per-item structure for multi-item clipboards.
  typealias SavedClipboardSnapshot = [SavedClipboardItem]

  private init() {}

  // MARK: - Basic Operations

  /// Copy text to the system clipboard
  func copy(_ text: String) {
    AppLogger.output.info("Clipboard: Copying \(text.count) characters to clipboard")
    AppLogger.output.debug("Clipboard: Text = \"\(text)\"")

    let clearResult = pasteboard.clearContents()
    AppLogger.output.info("Clipboard: clearContents() returned \(clearResult)")

    let setResult = pasteboard.setString(text, forType: .string)
    AppLogger.output.info("Clipboard: setString() returned \(setResult)")

    // Immediately verify
    if let verify = pasteboard.string(forType: .string) {
      AppLogger.output.info("Clipboard: Verification - got \(verify.count) chars back")
      if verify != text {
        AppLogger.output.error("Clipboard: MISMATCH! Set '\(text)' but got '\(verify)'")
      }
    } else {
      AppLogger.output.error("Clipboard: Verification FAILED - clipboard is empty!")
    }
  }

  /// Get the current clipboard contents
  func currentText() -> String? {
    pasteboard.string(forType: .string)
  }

  /// Check if clipboard has text content
  var hasText: Bool {
    pasteboard.string(forType: .string) != nil
  }

  // MARK: - Save/Restore for AXPaste Flow

  /// Capture current clipboard contents for later restoration.
  /// Returns an independent snapshot so concurrent deliver flows do not clobber each other.
  func captureContents() -> SavedClipboardSnapshot {
    if let pasteboardItems = pasteboard.pasteboardItems, !pasteboardItems.isEmpty {
      let snapshot = pasteboardItems.map { item in
        item.types.compactMap { type -> (NSPasteboard.PasteboardType, Data)? in
          guard let data = item.data(forType: type) else { return nil }
          return (type, data)
        }
      }
      let typeCount = snapshot.reduce(0) { $0 + $1.count }
      AppLogger.output.info(
        "Clipboard: Captured \(snapshot.count) pasteboard item(s) with \(typeCount) type payload(s)"
      )
      return snapshot
    }

    guard let types = pasteboard.types, !types.isEmpty else {
      AppLogger.output.info("Clipboard: No types to capture")
      return []
    }

    let legacyItem = types.compactMap { type -> (NSPasteboard.PasteboardType, Data)? in
      guard let data = pasteboard.data(forType: type) else { return nil }
      return (type, data)
    }

    AppLogger.output.info("Clipboard: Captured legacy pasteboard item with \(legacyItem.count) type payload(s)")
    return legacyItem.isEmpty ? [] : [legacyItem]
  }

  /// Save current clipboard contents for later restoration
  func saveContents() {
    savedItems = captureContents()
  }

  /// Restore previously captured clipboard contents
  func restoreContents(_ items: SavedClipboardSnapshot) {
    pasteboard.clearContents()

    guard !items.isEmpty else {
      AppLogger.output.info("Clipboard: Restored to empty")
      return
    }

    let pasteboardItems = items.map { typeDataPairs -> NSPasteboardItem in
      let item = NSPasteboardItem()
      for (type, data) in typeDataPairs {
        item.setData(data, forType: type)
      }
      return item
    }

    let writeResult = pasteboard.writeObjects(pasteboardItems)
    if writeResult {
      AppLogger.output.info("Clipboard: Restored \(pasteboardItems.count) pasteboard item(s)")
    } else {
      AppLogger.output.error("Clipboard: writeObjects failed while restoring \(pasteboardItems.count) item(s)")
    }
  }

  /// Restore previously saved clipboard contents
  func restoreContents() {
    guard let items = savedItems else {
      AppLogger.output.info("Clipboard: Nothing to restore")
      return
    }

    restoreContents(items)
    savedItems = nil
  }

  /// Discard saved contents (user wants to keep transcription on clipboard)
  func discardSavedContents() {
    savedItems = nil
  }

  /// Check if there are saved contents pending restore
  var hasSavedContents: Bool {
    guard let savedItems else { return false }
    return !savedItems.isEmpty
  }
}
