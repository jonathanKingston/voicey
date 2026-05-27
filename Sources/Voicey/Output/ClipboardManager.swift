import AppKit
import os

/// Manages clipboard operations
final class ClipboardManager: @unchecked Sendable {
  static let shared = ClipboardManager()

  private let pasteboard = NSPasteboard.general

  /// Stored clipboard data for restore (legacy single-flight save)
  private var savedItems: [(NSPasteboard.PasteboardType, Data)]?

  typealias SavedClipboardItems = [(NSPasteboard.PasteboardType, Data)]

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
  func captureContents() -> SavedClipboardItems {
    guard let types = pasteboard.types else {
      AppLogger.output.info("Clipboard: No types to capture")
      return []
    }

    let items = types.compactMap { type -> (NSPasteboard.PasteboardType, Data)? in
      guard let data = pasteboard.data(forType: type) else { return nil }
      return (type, data)
    }

    AppLogger.output.info("Clipboard: Captured \(items.count) items")
    return items
  }

  /// Save current clipboard contents for later restoration
  func saveContents() {
    savedItems = captureContents()
  }

  /// Restore previously captured clipboard contents
  func restoreContents(_ items: SavedClipboardItems) {
    guard !items.isEmpty else {
      AppLogger.output.info("Clipboard: Nothing to restore")
      return
    }

    pasteboard.clearContents()

    for (type, data) in items {
      pasteboard.setData(data, forType: type)
    }

    AppLogger.output.info("Clipboard: Restored \(items.count) items")
  }

  /// Restore previously saved clipboard contents
  func restoreContents() {
    guard let items = savedItems, !items.isEmpty else {
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
    savedItems != nil && !(savedItems?.isEmpty ?? true)
  }
}
