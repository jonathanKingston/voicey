import AppKit
import Carbon.HIToolbox

enum KeyboardSimulator {
  /// Dispatches one Cmd+V to the intended PID. True means dispatched, never "inserted".
  /// Do not follow this with another insertion strategy: delivery may be asynchronous.
  @discardableResult
  static func postPasteCommandToPid(_ pid: pid_t) -> Bool {
    guard let source = CGEventSource(stateID: .privateState),
          let keyDown = CGEvent(
            keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true
          ),
          let keyUp = CGEvent(
            keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false
          ) else {
      AppLogger.output.error("Auto-paste: could not construct keyboard events; nothing dispatched")
      return false
    }

    keyDown.flags = .maskCommand
    keyUp.flags = .maskCommand
    keyDown.postToPid(pid)
    keyUp.postToPid(pid)
    AppLogger.output.info("Auto-paste: Cmd+V dispatched to PID \(pid); delivery unconfirmed")
    return true
  }
}
