import ApplicationServices
import Carbon.HIToolbox
import Foundation

/// Simulates keyboard input for direct distribution builds only.
///
/// IMPORTANT:
/// - Requires Accessibility permission when enabled.
enum KeyboardSimulator {
  static func simulatePaste() {
    guard AXIsProcessTrusted() else {
      AppLogger.output.error("Auto-paste requested but Accessibility permission is not granted")
      return
    }

    guard let source = CGEventSource(stateID: .combinedSessionState) else {
      AppLogger.output.error("Failed to create CGEventSource for auto-paste")
      return
    }

    let vKey = CGKeyCode(kVK_ANSI_V)
    let cmdDown = CGEventFlags.maskCommand

    guard
      let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
      let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
    else {
      AppLogger.output.error("Failed to create CGEvents for auto-paste")
      return
    }

    keyDown.flags = cmdDown
    keyUp.flags = cmdDown

    keyDown.post(tap: .cgSessionEventTap)
    keyUp.post(tap: .cgSessionEventTap)
  }
}
