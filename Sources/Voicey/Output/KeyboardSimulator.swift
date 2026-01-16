import AppKit
import Carbon.HIToolbox
import os

/// Simulates keyboard input to paste text into the active application
final class KeyboardSimulator {
    static let shared = KeyboardSimulator()
    
    private init() {}
    
    /// Simulate Cmd+V to paste from clipboard using AppleScript (most reliable)
    func simulatePaste() {
        // Log current state for debugging
        let frontApp = NSWorkspace.shared.frontmostApplication
        AppLogger.output.info("Paste: Current frontmost app: \(frontApp?.localizedName ?? "none") (bundle: \(frontApp?.bundleIdentifier ?? "?"))")
        AppLogger.output.info("Paste: Clipboard has text: \(ClipboardManager.shared.hasText)")
        if let text = ClipboardManager.shared.currentText() {
            AppLogger.output.info("Paste: Clipboard content length: \(text.count) chars")
        }
        
        AppLogger.output.info("Paste: Attempting AppleScript method...")
        
        let script = """
        tell application "System Events"
            keystroke "v" using command down
        end tell
        """
        
        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            appleScript.executeAndReturnError(&error)
            if let error = error {
                AppLogger.output.error("Paste: AppleScript error: \(error)")
                AppLogger.output.info("Paste: Falling back to CGEvent method...")
                simulatePasteViaCGEvent()
            } else {
                AppLogger.output.info("Paste: AppleScript paste sent successfully")
            }
        } else {
            AppLogger.output.error("Paste: Failed to create AppleScript, using CGEvent fallback")
            simulatePasteViaCGEvent()
        }
    }
    
    /// Fallback: Simulate Cmd+V using CGEvent
    private func simulatePasteViaCGEvent() {
        AppLogger.output.info("Paste: Using CGEvent method...")
        
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            AppLogger.output.error("Paste: Failed to create CGEventSource - this usually means accessibility permissions are missing")
            return
        }
        
        let vKeyCode = CGKeyCode(kVK_ANSI_V)
        
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false) else {
            AppLogger.output.error("Paste: Failed to create CGEvent key events")
            return
        }
        
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        
        keyDown.post(tap: .cgSessionEventTap)
        keyUp.post(tap: .cgSessionEventTap)
        
        AppLogger.output.info("Paste: CGEvent paste posted successfully")
    }
    
    /// Type text character by character (for apps that don't support paste)
    func typeText(_ text: String) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        
        for char in text {
            let charString = String(char)
            
            if let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
                var unicodeString = Array(charString.utf16)
                event.keyboardSetUnicodeString(stringLength: unicodeString.count, unicodeString: &unicodeString)
                event.post(tap: .cgSessionEventTap)
            }
            
            usleep(1000)
        }
    }
}
