import ApplicationServices
import AppKit
import Carbon.HIToolbox
import Foundation

/// Pastes text using Accessibility API instead of CGEvents.
/// This approach works in sandboxed apps since it uses AXPasteAction
/// which is like the user pressing ⌘V through the accessibility framework.
enum AccessibilityPaster {

  /// Attempts to paste text into the currently focused text field using Accessibility API.
  /// NOTE: Assumes text is already on clipboard before calling this method.
  /// - Parameter text: The text to insert (used as fallback for direct value manipulation)
  /// - Returns: `true` if successful, `false` if it couldn't paste
  @discardableResult
  static func paste(_ text: String) -> Bool {
    debugPrint("🔌 AccessibilityPaster: Attempting to paste \(text.count) characters", category: "AX")

    guard AXIsProcessTrusted() else {
      debugPrint("❌ AccessibilityPaster: Accessibility permission not granted", category: "AX")
      AppLogger.output.error("AccessibilityPaster: Accessibility permission not granted")
      return false
    }
    debugPrint("✅ AccessibilityPaster: AXIsProcessTrusted() = true", category: "AX")

    // Get frontmost app for fallback attempts
    guard let frontApp = NSWorkspace.shared.frontmostApplication else {
      debugPrint("❌ AccessibilityPaster: No frontmost application", category: "AX")
      return false
    }
    let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)

    // Try to get focused element
    let focusedElement = getFocusedElement()

    if let element = focusedElement {
      // Log info about the focused element for debugging
      logElementInfo(element)

      // METHOD 1: AXPasteAction on focused element (most reliable for sandboxed apps)
      // This is like the user pressing ⌘V but through the accessibility framework
      if performPasteAction(on: element) {
        return true
      }

      // METHOD 2: Set selected text (works for native text fields)
      if insertViaSelectedText(element: element, text: text) {
        return true
      }

      // METHOD 3: Insert at cursor via value manipulation
      if let insertResult = insertAtCursor(element: element, text: text), insertResult {
        return true
      }

      // METHOD 4: Replace entire value (last resort for native fields)
      if replaceValue(element: element, text: text) {
        return true
      }
    } else {
      debugPrint("⚠️ AccessibilityPaster: Could not get focused element", category: "AX")
    }

    // METHOD 5: AXPasteAction on app element
    // Some apps (especially Electron) respond to paste on the app element even when
    // we can't get the focused element, or when the focused element doesn't support paste
    debugPrint("🔧 AccessibilityPaster: Trying AXPasteAction on app element", category: "AX")
    if performPasteAction(on: appElement) {
      return true
    }

    // METHOD 6: CGEventPost - Last resort fallback
    // Voice Type uses this successfully from sandbox. Post Cmd+V via CGEvent.
    // This simulates the keyboard shortcut directly rather than using accessibility actions.
    debugPrint("🔧 AccessibilityPaster: Trying CGEventPost as final fallback", category: "AX")
    AppLogger.output.info("AccessibilityPaster: Trying CGEventPost (Cmd+V simulation) as final fallback")

    // Small delay before posting to ensure target app has focus
    Thread.sleep(forTimeInterval: 0.05)

    // Try system-wide post first (Voice Type's approach)
    if KeyboardSimulator.postPasteCommand() {
      debugPrint("✅ AccessibilityPaster: Posted Cmd+V via CGEventPost - paste should occur", category: "AX")
      AppLogger.output.info("AccessibilityPaster: CGEventPost succeeded - Cmd+V posted")
      // Small delay for the event to be processed
      Thread.sleep(forTimeInterval: 0.1)
      return true
    }

    // Fallback: Try posting to specific PID
    if KeyboardSimulator.postPasteCommandToPid(frontApp.processIdentifier) {
      debugPrint("✅ AccessibilityPaster: Posted Cmd+V via postToPid - paste should occur", category: "AX")
      AppLogger.output.info("AccessibilityPaster: CGEventPostToPid succeeded")
      Thread.sleep(forTimeInterval: 0.1)
      return true
    }

    // All methods failed - text is already on clipboard, user can paste manually
    debugPrint("❌ AccessibilityPaster: All methods failed (including CGEventPost)", category: "AX")
    AppLogger.output.warning("AccessibilityPaster: All paste methods failed - user should paste manually with ⌘V")
    return false
  }

  #if VOICEY_DIRECT_DISTRIBUTION
  /// Post Cmd+V directly to the frontmost process via CGEventPostToPid
  /// This targets a specific process rather than posting system-wide
  /// Only available in direct distribution builds (blocked in sandbox)
  private static func pasteViaCGEventToPid(to pid: pid_t, appName: String?) -> Bool {
    debugPrint("🔧 AccessibilityPaster: Trying CGEventPostToPid", category: "AX")
    debugPrint("🎹 AccessibilityPaster: Posting Cmd+V to pid \(pid) (\(appName ?? "unknown"))", category: "AX")

    guard let source = CGEventSource(stateID: .combinedSessionState) else {
      debugPrint("❌ AccessibilityPaster: Failed to create CGEventSource", category: "AX")
      return false
    }

    let vKeyCode = CGKeyCode(kVK_ANSI_V)

    guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
          let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false) else {
      debugPrint("❌ AccessibilityPaster: Failed to create CGEvents", category: "AX")
      return false
    }

    // Set command flag
    keyDown.flags = .maskCommand
    keyUp.flags = .maskCommand

    // Post to specific process instead of system-wide
    keyDown.postToPid(pid)
    keyUp.postToPid(pid)

    debugPrint("✅ AccessibilityPaster: Posted Cmd+V via CGEventPostToPid", category: "AX")
    AppLogger.output.info("AccessibilityPaster: Posted Cmd+V via CGEventPostToPid to pid \(pid)")
    return true
  }
  #endif

  /// Performs the AXPaste action on an element (like pressing ⌘V)
  /// This is the most reliable method for sandboxed apps
  private static func performPasteAction(on element: AXUIElement) -> Bool {
    debugPrint("🔧 AccessibilityPaster: Trying AXPasteAction", category: "AX")

    let pasteActionName = "AXPaste"

    // Try the paste action directly first - some apps (especially Electron) don't
    // properly report their supported actions but still respond to them
    let result = AXUIElementPerformAction(element, pasteActionName as CFString)
    if result == .success {
      debugPrint("✅ AccessibilityPaster: AXPasteAction succeeded!", category: "AX")
      AppLogger.output.info("AccessibilityPaster: AXPasteAction succeeded")
      return true
    }

    // Log why it failed for debugging
    debugPrint("❌ AccessibilityPaster: AXPasteAction failed with: \(result.rawValue)", category: "AX")

    // Log available actions for debugging (don't gate on this)
    var actions: CFTypeRef?
    let actionsResult = AXUIElementCopyAttributeValue(
      element,
      "AXActions" as CFString,
      &actions
    )

    if actionsResult == .success, let actionList = actions as? [String] {
      debugPrint("📋 AccessibilityPaster: Element's reported actions: \(actionList)", category: "AX")
      if !actionList.contains(pasteActionName) {
        debugPrint("⚠️ AccessibilityPaster: Note - AXPaste not in reported actions", category: "AX")
      }
    } else {
      debugPrint("⚠️ AccessibilityPaster: Could not get actions list (error: \(actionsResult.rawValue))", category: "AX")
    }

    return false
  }

  /// Try to get the focused element using multiple approaches
  private static func getFocusedElement() -> AXUIElement? {
    // Approach 1: System-wide focused element
    let systemWide = AXUIElementCreateSystemWide()
    var focusedElement: CFTypeRef?
    let focusResult = AXUIElementCopyAttributeValue(
      systemWide,
      kAXFocusedUIElementAttribute as CFString,
      &focusedElement
    )

    if focusResult == .success,
       let focused = focusedElement,
       CFGetTypeID(focused) == AXUIElementGetTypeID() {
      debugPrint("✅ AccessibilityPaster: Got focused element via system-wide", category: "AX")
      // swiftlint:disable:next force_cast
      return (focused as! AXUIElement)
    }
    debugPrint("⚠️ AccessibilityPaster: System-wide focused element failed (error: \(focusResult.rawValue))", category: "AX")

    // Approach 2: Get frontmost app, then its focused element
    guard let frontApp = NSWorkspace.shared.frontmostApplication else {
      debugPrint("❌ AccessibilityPaster: No frontmost application", category: "AX")
      return nil
    }

    debugPrint("🔍 AccessibilityPaster: Trying via frontmost app: \(frontApp.localizedName ?? "unknown") (pid: \(frontApp.processIdentifier))", category: "AX")

    let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)

    // Try to get focused UI element from the app
    var appFocused: CFTypeRef?
    let appFocusResult = AXUIElementCopyAttributeValue(
      appElement,
      kAXFocusedUIElementAttribute as CFString,
      &appFocused
    )

    if appFocusResult == .success,
       let focused = appFocused,
       CFGetTypeID(focused) == AXUIElementGetTypeID() {
      debugPrint("✅ AccessibilityPaster: Got focused element via app element", category: "AX")
      // swiftlint:disable:next force_cast
      return (focused as! AXUIElement)
    }
    debugPrint("⚠️ AccessibilityPaster: App focused element failed (error: \(appFocusResult.rawValue))", category: "AX")

    // Approach 3: Get focused window, then try to find a text field
    var focusedWindow: CFTypeRef?
    let windowResult = AXUIElementCopyAttributeValue(
      appElement,
      kAXFocusedWindowAttribute as CFString,
      &focusedWindow
    )

    if windowResult == .success,
       let window = focusedWindow,
       CFGetTypeID(window) == AXUIElementGetTypeID() {
      debugPrint("🔍 AccessibilityPaster: Got focused window, searching for text field...", category: "AX")
      // swiftlint:disable:next force_cast
      let windowElement = window as! AXUIElement

      // Try to get focused element from window
      var windowFocused: CFTypeRef?
      let windowFocusResult = AXUIElementCopyAttributeValue(
        windowElement,
        kAXFocusedUIElementAttribute as CFString,
        &windowFocused
      )

      if windowFocusResult == .success,
         let focused = windowFocused,
         CFGetTypeID(focused) == AXUIElementGetTypeID() {
        debugPrint("✅ AccessibilityPaster: Got focused element via window", category: "AX")
        // swiftlint:disable:next force_cast
        return (focused as! AXUIElement)
      }
      debugPrint("⚠️ AccessibilityPaster: Window focused element failed (error: \(windowFocusResult.rawValue))", category: "AX")

      // Approach 4: Search window's children for text input elements
      // This can help with Electron apps that don't properly report focused elements
      // Use maxDepth 10 since Electron apps can have deep accessibility trees
      if let textElement = findTextInputElement(in: windowElement, depth: 0, maxDepth: 10) {
        debugPrint("✅ AccessibilityPaster: Found text input element via tree search", category: "AX")
        return textElement
      }
    } else {
      debugPrint("⚠️ AccessibilityPaster: Could not get focused window (error: \(windowResult.rawValue))", category: "AX")
    }

    return nil
  }

  /// Recursively search for a text input element in the accessibility tree
  /// This helps find text fields in Electron apps that don't properly report focused elements
  private static func findTextInputElement(in element: AXUIElement, depth: Int, maxDepth: Int) -> AXUIElement? {
    guard depth < maxDepth else {
      if depth == maxDepth {
        debugPrint("🌳 AccessibilityPaster: Max depth \(maxDepth) reached", category: "AX")
      }
      return nil
    }

    // Check if this element is a text input type
    var role: CFTypeRef?
    _ = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
    let roleString = (role as? String) ?? "unknown"

    // Log all roles at shallow depths so we can see the tree structure
    if depth <= 2 {
      debugPrint("🌳 AccessibilityPaster: [depth \(depth)] role=\(roleString)", category: "AX")
    }

    // Text input roles we're looking for
    let textInputRoles = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXWebArea", "AXGroup"]
    if textInputRoles.contains(roleString) {
      // Check if this element has focus
      var focused: CFTypeRef?
      _ = AXUIElementCopyAttributeValue(element, "AXFocused" as CFString, &focused)
      let isFocused = (focused as? Bool) ?? false
      debugPrint("🌳 AccessibilityPaster: Found \(roleString) at depth \(depth), focused=\(isFocused)", category: "AX")

      if isFocused {
        debugPrint("✅ AccessibilityPaster: Found focused \(roleString) at depth \(depth)", category: "AX")
        return element
      }

      // For AXWebArea (Electron's main content), return it as a target for paste
      if roleString == "AXWebArea" {
        debugPrint("🌳 AccessibilityPaster: Returning AXWebArea as potential target", category: "AX")
        return element
      }
    }

    // Get children and search recursively
    var children: CFTypeRef?
    let childrenResult = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)

    guard childrenResult == .success, let childArray = children as? [AXUIElement] else {
      return nil
    }

    if depth == 0 {
      debugPrint("🌳 AccessibilityPaster: Starting tree search from \(roleString), \(childArray.count) children", category: "AX")
    }

    // Limit breadth search to avoid performance issues
    let maxChildren = min(childArray.count, 50)
    for idx in 0..<maxChildren {
      if let found = findTextInputElement(in: childArray[idx], depth: depth + 1, maxDepth: maxDepth) {
        return found
      }
    }

    return nil
  }

  /// Log information about an AXUIElement for debugging
  private static func logElementInfo(_ element: AXUIElement) {
    var role: CFTypeRef?
    var roleDesc: CFTypeRef?
    var title: CFTypeRef?

    AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
    AXUIElementCopyAttributeValue(element, kAXRoleDescriptionAttribute as CFString, &roleDesc)
    AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title)

    let roleStr = (role as? String) ?? "unknown"
    let roleDescStr = (roleDesc as? String) ?? "unknown"
    let titleStr = (title as? String) ?? "none"

    debugPrint("📍 AccessibilityPaster: Focused element - role: \(roleStr), roleDesc: \(roleDescStr), title: \(titleStr)", category: "AX")
    AppLogger.output.info("AccessibilityPaster: Focused element - role: \(roleStr), roleDesc: \(roleDescStr)")
  }

  /// Insert text at the current cursor position by manipulating selection
  private static func insertAtCursor(element: AXUIElement, text: String) -> Bool? {
    debugPrint("🔧 AccessibilityPaster: Trying insertAtCursor", category: "AX")

    // Get current value
    var currentValue: CFTypeRef?
    let valueResult = AXUIElementCopyAttributeValue(
      element,
      kAXValueAttribute as CFString,
      &currentValue
    )

    guard valueResult == .success, let currentString = currentValue as? String else {
      debugPrint("⚠️ AccessibilityPaster: Could not get current value (error: \(valueResult.rawValue))", category: "AX")
      return nil
    }

    // Get selected text range
    var selectedRange: CFTypeRef?
    let rangeResult = AXUIElementCopyAttributeValue(
      element,
      kAXSelectedTextRangeAttribute as CFString,
      &selectedRange
    )

    guard rangeResult == .success, let rangeValue = selectedRange else {
      debugPrint("⚠️ AccessibilityPaster: Could not get selected range (error: \(rangeResult.rawValue))", category: "AX")
      return nil
    }

    // Extract the range
    var range = CFRange(location: 0, length: 0)
    guard CFGetTypeID(rangeValue) == AXValueGetTypeID(),
          // swiftlint:disable:next force_cast
          AXValueGetValue(rangeValue as! AXValue, .cfRange, &range) else {
      debugPrint("⚠️ AccessibilityPaster: Could not extract CFRange from AXValue", category: "AX")
      return nil
    }

    debugPrint("📝 AccessibilityPaster: Current value length: \(currentString.count), selection at: \(range.location), length: \(range.length)", category: "AX")
    AppLogger.output.info("AccessibilityPaster: Current value length: \(currentString.count), selection at: \(range.location), length: \(range.length)")

    // Build the new string with text inserted at cursor position
    let nsString = currentString as NSString
    let insertLocation = min(range.location, nsString.length)
    let replaceLength = min(range.length, nsString.length - insertLocation)
    let replaceRange = NSRange(location: insertLocation, length: replaceLength)
    let newString = nsString.replacingCharacters(in: replaceRange, with: text)

    debugPrint("📝 AccessibilityPaster: Setting new value with \(newString.count) characters", category: "AX")

    // Set the new value
    let setResult = AXUIElementSetAttributeValue(
      element,
      kAXValueAttribute as CFString,
      newString as CFTypeRef
    )

    guard setResult == .success else {
      debugPrint("❌ AccessibilityPaster: Failed to set value (error: \(setResult.rawValue))", category: "AX")
      AppLogger.output.error("AccessibilityPaster: Failed to set value (error: \(setResult.rawValue))")
      return false
    }

    // Move cursor to end of inserted text
    let newCursorPosition = insertLocation + text.count
    var newRange = CFRange(location: newCursorPosition, length: 0)
    if let newRangeValue = AXValueCreate(.cfRange, &newRange) {
      AXUIElementSetAttributeValue(
        element,
        kAXSelectedTextRangeAttribute as CFString,
        newRangeValue
      )
    }

    debugPrint("✅ AccessibilityPaster: Successfully inserted text at cursor!", category: "AX")
    AppLogger.output.info("AccessibilityPaster: Successfully inserted text at cursor")
    return true
  }

  /// Insert text by setting the selected text attribute (works in some apps)
  private static func insertViaSelectedText(element: AXUIElement, text: String) -> Bool {
    debugPrint("🔧 AccessibilityPaster: Trying insertViaSelectedText", category: "AX")

    // Check if selected text attribute is settable
    var isSettable: DarwinBoolean = false
    let settableResult = AXUIElementIsAttributeSettable(
      element,
      kAXSelectedTextAttribute as CFString,
      &isSettable
    )

    debugPrint("🔍 AccessibilityPaster: kAXSelectedTextAttribute settable check: result=\(settableResult.rawValue), isSettable=\(isSettable.boolValue)", category: "AX")

    guard settableResult == .success, isSettable.boolValue else {
      debugPrint("❌ AccessibilityPaster: Selected text attribute not settable", category: "AX")
      AppLogger.output.warning("AccessibilityPaster: Selected text attribute not settable")
      return false
    }

    // Set the selected text (replaces current selection with our text)
    let setResult = AXUIElementSetAttributeValue(
      element,
      kAXSelectedTextAttribute as CFString,
      text as CFTypeRef
    )

    if setResult == .success {
      debugPrint("✅ AccessibilityPaster: Successfully set selected text!", category: "AX")
      AppLogger.output.info("AccessibilityPaster: Successfully set selected text")
      return true
    } else {
      debugPrint("❌ AccessibilityPaster: Failed to set selected text (error: \(setResult.rawValue))", category: "AX")
      AppLogger.output.error("AccessibilityPaster: Failed to set selected text (error: \(setResult.rawValue))")
      return false
    }
  }

  /// Replace the entire value of the text field (fallback)
  private static func replaceValue(element: AXUIElement, text: String) -> Bool {
    debugPrint("🔧 AccessibilityPaster: Trying replaceValue (append mode)", category: "AX")

    // Check if this element has a settable value attribute
    var isSettable: DarwinBoolean = false
    let settableResult = AXUIElementIsAttributeSettable(
      element,
      kAXValueAttribute as CFString,
      &isSettable
    )

    guard settableResult == .success, isSettable.boolValue else {
      debugPrint("⚠️ AccessibilityPaster: kAXValueAttribute is not settable", category: "AX")
      return false
    }

    // Get current value to append to (if desired) or just set
    var currentValue: CFTypeRef?
    _ = AXUIElementCopyAttributeValue(
      element,
      kAXValueAttribute as CFString,
      &currentValue
    )

    // For now, just append to existing text
    let existingText = (currentValue as? String) ?? ""
    let newText = existingText + text

    debugPrint("📝 AccessibilityPaster: Appending to existing text (\(existingText.count) chars + \(text.count) chars)", category: "AX")

    let setResult = AXUIElementSetAttributeValue(
      element,
      kAXValueAttribute as CFString,
      newText as CFTypeRef
    )

    if setResult == .success {
      debugPrint("✅ AccessibilityPaster: Successfully replaced value (appended text)!", category: "AX")
      AppLogger.output.info("AccessibilityPaster: Successfully replaced value (appended text)")
      return true
    } else {
      debugPrint("❌ AccessibilityPaster: Failed to set value (error: \(setResult.rawValue))", category: "AX")
      AppLogger.output.error("AccessibilityPaster: Failed to set value (error: \(setResult.rawValue))")
      return false
    }
  }
}
