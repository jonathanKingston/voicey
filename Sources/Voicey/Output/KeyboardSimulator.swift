import AppKit
import Carbon.HIToolbox

/// Keyboard simulation using CGEventPost
/// Used as a last-resort fallback for pasting when Accessibility API methods fail.
/// Voice Type (a sandboxed App Store app) uses this approach successfully.
enum KeyboardSimulator {

  /// Post Cmd+V via CGEventPost to trigger paste in the frontmost app.
  /// This simulates the exact sequence Voice Type uses:
  /// 1. flagsChanged → set Command
  /// 2. keyDown V with Command
  /// 3. keyUp V with Command  
  /// 4. flagsChanged → clear modifiers
  @discardableResult
  static func postPasteCommand() -> Bool {
    debugPrint("🔧 KeyboardSimulator: Posting Cmd+V via CGEventPost", category: "AX")

    guard let source = CGEventSource(stateID: .combinedSessionState) else {
      debugPrint("❌ KeyboardSimulator: Failed to create CGEventSource", category: "AX")
      return false
    }

    let vKeyCode = CGKeyCode(kVK_ANSI_V)

    // Create key events
    guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
          let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false) else {
      debugPrint("❌ KeyboardSimulator: Failed to create key events", category: "AX")
      return false
    }

    // Create flags changed events (mimics Voice Type's exact sequence)
    guard let flagsDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
          let flagsUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
      debugPrint("❌ KeyboardSimulator: Failed to create flag events", category: "AX")
      return false
    }

    // Set Command flag on all events that need it
    keyDown.flags = .maskCommand
    keyUp.flags = .maskCommand
    flagsDown.flags = .maskCommand
    flagsDown.type = .flagsChanged
    flagsUp.flags = []
    flagsUp.type = .flagsChanged

    // Post the complete sequence (matches Voice Type's pattern)
    flagsDown.post(tap: .cgSessionEventTap)  // Set Command modifier
    keyDown.post(tap: .cgSessionEventTap)    // V key down with Command
    keyUp.post(tap: .cgSessionEventTap)      // V key up with Command
    flagsUp.post(tap: .cgSessionEventTap)    // Clear modifiers

    debugPrint("✅ KeyboardSimulator: Posted Cmd+V sequence via CGEventPost", category: "AX")
    AppLogger.output.info("KeyboardSimulator: Posted Cmd+V via CGEventPost (system-wide)")
    return true
  }

  /// Post Cmd+V to a specific process by PID.
  /// Fallback if system-wide posting doesn't work.
  @discardableResult
  static func postPasteCommandToPid(_ pid: pid_t) -> Bool {
    debugPrint("🔧 KeyboardSimulator: Posting Cmd+V to PID \(pid)", category: "AX")

    guard let source = CGEventSource(stateID: .combinedSessionState) else {
      debugPrint("❌ KeyboardSimulator: Failed to create CGEventSource", category: "AX")
      return false
    }

    let vKeyCode = CGKeyCode(kVK_ANSI_V)

    guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
          let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false) else {
      debugPrint("❌ KeyboardSimulator: Failed to create key events", category: "AX")
      return false
    }

    keyDown.flags = .maskCommand
    keyUp.flags = .maskCommand

    keyDown.postToPid(pid)
    keyUp.postToPid(pid)

    debugPrint("✅ KeyboardSimulator: Posted Cmd+V to PID \(pid)", category: "AX")
    AppLogger.output.info("KeyboardSimulator: Posted Cmd+V to PID \(pid)")
    return true
  }
}
