import AppKit
import Carbon.HIToolbox

/// Simulates keyboard input to paste text into the active application
final class KeyboardSimulator {
    static let shared = KeyboardSimulator()
    
    private init() {}
    
    /// Simulate Cmd+V to paste from clipboard using AppleScript (most reliable)
    func simulatePaste() {
        log("Simulating paste via AppleScript...")
        
        let script = """
        tell application "System Events"
            keystroke "v" using command down
        end tell
        """
        
        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            appleScript.executeAndReturnError(&error)
            if let error = error {
                log("AppleScript error: \(error)")
                // Fallback to CGEvent
                simulatePasteViaCGEvent()
            } else {
                log("Paste sent via AppleScript successfully")
            }
        } else {
            log("Failed to create AppleScript, using CGEvent fallback")
            simulatePasteViaCGEvent()
        }
    }
    
    /// Fallback: Simulate Cmd+V using CGEvent
    private func simulatePasteViaCGEvent() {
        log("Using CGEvent fallback...")
        
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            log("Failed to create event source")
            return
        }
        
        let vKeyCode = CGKeyCode(kVK_ANSI_V)
        
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false) else {
            log("Failed to create key events")
            return
        }
        
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        
        keyDown.post(tap: .cgSessionEventTap)
        keyUp.post(tap: .cgSessionEventTap)
        
        log("CGEvent paste posted")
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
