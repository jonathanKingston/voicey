import ApplicationServices
import AppKit
import Foundation
import VoiceyCore

/// Uses the editor's normal clipboard path so selections, rich content and input events survive.
/// AX is read only: an AX setter's success does not prove the application's draft changed.
enum AccessibilityPaster {
  @MainActor
  static func paste(_ text: String, targetPID: pid_t) async -> PasteAttemptOutcome {
    guard AXIsProcessTrusted(), NSPasteboard.general.string(forType: .string) == text else {
      AppLogger.output.warning("Auto-paste: not attempted; AX permission or clipboard unavailable")
      return .notAttempted
    }

    let environment = ClipboardPasteEnvironment(targetPID: targetPID)
    AppLogger.output.info(
      "Auto-paste: method=keyboardClipboard targetPID=\(targetPID) role=\(environment.focusedRole)"
    )
    let outcome = await PasteAttempt.perform(text: text, environment: environment)
    AppLogger.output.info(
      "Auto-paste: method=keyboardClipboard outcome=\(outcome.rawValue); AX observation only, no retry"
    )
    return outcome
  }
}

@MainActor
private final class ClipboardPasteEnvironment: PasteAttemptEnvironment {
  let targetPID: pid_t
  private let element: AXUIElement?
  let focusedRole: String

  init(targetPID: pid_t) {
    self.targetPID = targetPID
    let app = AXUIElementCreateApplication(targetPID)
    // Limit a hung application's AX queries.
    AXUIElementSetMessagingTimeout(app, 0.1)
    element = Self.focusedTextInput(in: app)
    focusedRole = element.flatMap { Self.attribute($0, kAXRoleAttribute) as? String } ?? "unavailable"
  }

  var targetIsActive: Bool {
    NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID
  }

  func postPaste() -> Bool {
    guard targetIsActive else { return false }
    // PID routing avoids a global shortcut reaching another app if activation changes.
    return KeyboardSimulator.postPasteCommandToPid(targetPID)
  }

  func waitForObservation() async {
    do {
      try await Task.sleep(nanoseconds: 20_000_000)
    } catch {
      // Cancellation leaves delivery ambiguous; the caller must retain the clipboard.
      AppLogger.output.debug("Auto-paste: observation sleep cancelled")
    }
  }

  func snapshot() -> PasteTextSnapshot? {
    guard let element, Self.attribute(element, kAXFocusedAttribute) as? Bool == true,
          let value = Self.attribute(element, kAXValueAttribute) as? String,
          let rangeValue = Self.attribute(element, kAXSelectedTextRangeAttribute),
          CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return nil }
    var range = CFRange()
    // swiftlint:disable:next force_cast
    guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &range) else { return nil }
    return PasteTextSnapshot(value: value, selection: NSRange(location: range.location, length: range.length))
  }

  private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
  }

  private static func focusedTextInput(in app: AXUIElement) -> AXUIElement? {
    if let focused = attribute(app, kAXFocusedUIElementAttribute),
       CFGetTypeID(focused) == AXUIElementGetTypeID() {
      // swiftlint:disable:next force_cast
      let root = focused as! AXUIElement
      if let input = findFocusedInput(root) { return input }
    }
    guard let window = attribute(app, kAXFocusedWindowAttribute),
          CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
    // swiftlint:disable:next force_cast
    return findFocusedInput(window as! AXUIElement)
  }

  private static func findFocusedInput(_ element: AXUIElement) -> AXUIElement? {
    FocusedTextInputSearch.find(
      in: element,
      role: { attribute($0, kAXRoleAttribute) as? String },
      isFocused: { attribute($0, kAXFocusedAttribute) as? Bool == true },
      children: { attribute($0, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
    )
  }
}
