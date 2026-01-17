import AppKit
import os

/// Manages clipboard operations
final class ClipboardManager {
  static let shared = ClipboardManager()

  private let pasteboard = NSPasteboard.general

  private init() {}

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
}
