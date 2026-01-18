// Auto-paste functionality is only available in direct distribution builds.
// App Store/TestFlight builds are sandboxed and cannot post CGEvents to other apps.

#if VOICEY_DIRECT_DISTRIBUTION

import ApplicationServices
import Carbon.HIToolbox
import Foundation

/// Simulates keyboard input for direct distribution builds only.
///
/// IMPORTANT:
/// - Only available in non-sandboxed (direct distribution) builds.
/// - Requires Accessibility permission when enabled.
/// - Sandboxed apps (App Store/TestFlight) cannot post CGEvents to other apps.
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

#endif
