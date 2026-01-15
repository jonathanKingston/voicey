import AppKit

/// Manages clipboard operations
final class ClipboardManager {
    static let shared = ClipboardManager()
    
    private let pasteboard = NSPasteboard.general
    
    private init() {}
    
    /// Copy text to the system clipboard
    func copy(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
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
