import ApplicationServices
import AppKit
import Carbon.HIToolbox
import Foundation

/// Pastes text using Accessibility API instead of CGEvents.
/// This approach may work in sandboxed apps since it doesn't simulate keyboard input.
enum AccessibilityPaster {
  
  /// Attempts to paste text into the currently focused text field using Accessibility API.
  /// - Parameter text: The text to insert
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
    
    // Try to get focused element - with retries since focus may not have settled
    guard let element = getFocusedElement() else {
      debugPrint("⚠️ AccessibilityPaster: Could not get focused element, trying CGEventPostToPid fallback", category: "AX")
      AppLogger.output.warning("AccessibilityPaster: Could not get focused element, trying keyboard event fallback")
      // Can't get focused element (common with Electron apps like Cursor)
      // Try posting Cmd+V directly to the process as a last resort
      return pasteViaCGEventToPid()
    }
    
    // Log info about the focused element for debugging
    logElementInfo(element)
    
    // Check if this element has a settable value attribute (i.e., is a text field)
    var isSettable: DarwinBoolean = false
    let settableResult = AXUIElementIsAttributeSettable(
      element,
      kAXValueAttribute as CFString,
      &isSettable
    )
    
    debugPrint("🔍 AccessibilityPaster: kAXValueAttribute settable check: result=\(settableResult.rawValue), isSettable=\(isSettable.boolValue)", category: "AX")
    
    guard settableResult == .success, isSettable.boolValue else {
      debugPrint("⚠️ AccessibilityPaster: Focused element doesn't have a settable value attribute, trying selected text", category: "AX")
      AppLogger.output.warning("AccessibilityPaster: Focused element doesn't have a settable value attribute")
      // Try inserting via selected text attribute instead
      if insertViaSelectedText(element: element, text: text) {
        return true
      }
      // Final fallback: try posting Cmd+V via CGEvent to specific process
      return pasteViaCGEventToPid()
    }
    
    // Try to get the current value and selection range to insert at cursor
    if let insertResult = insertAtCursor(element: element, text: text), insertResult {
      return true
    }
    
    // Fallback: replace the entire value (less ideal but works)
    debugPrint("⚠️ AccessibilityPaster: insertAtCursor failed, falling back to value replacement", category: "AX")
    AppLogger.output.info("AccessibilityPaster: Falling back to value replacement")
    if replaceValue(element: element, text: text) {
      return true
    }
    
    // Final fallback: try posting Cmd+V via CGEvent to specific process
    return pasteViaCGEventToPid()
  }
  
  /// Paste by posting Cmd+V via CGEventPostToPid (targets specific process)
  /// This is different from CGEventPost(.cgSessionEventTap) which posts system-wide
  private static func pasteViaCGEventToPid() -> Bool {
    debugPrint("🔧 AccessibilityPaster: Trying pasteViaCGEventToPid", category: "AX")
    
    guard let frontApp = NSWorkspace.shared.frontmostApplication else {
      debugPrint("❌ AccessibilityPaster: No frontmost application for CGEventPostToPid", category: "AX")
      return false
    }
    
    let pid = frontApp.processIdentifier
    debugPrint("🎹 AccessibilityPaster: Posting Cmd+V to pid \(pid) (\(frontApp.localizedName ?? "unknown"))", category: "AX")
    
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
    
    // Post to specific process instead of session
    keyDown.postToPid(pid)
    keyUp.postToPid(pid)
    
    debugPrint("✅ AccessibilityPaster: Posted Cmd+V via CGEventPostToPid!", category: "AX")
    AppLogger.output.info("AccessibilityPaster: Posted Cmd+V via CGEventPostToPid to pid \(pid)")
    return true
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
    
    if focusResult == .success, let focused = focusedElement {
      debugPrint("✅ AccessibilityPaster: Got focused element via system-wide", category: "AX")
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
    
    if appFocusResult == .success, let focused = appFocused {
      debugPrint("✅ AccessibilityPaster: Got focused element via app element", category: "AX")
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
    
    if windowResult == .success, let window = focusedWindow {
      debugPrint("🔍 AccessibilityPaster: Got focused window, searching for text field...", category: "AX")
      
      // Try to get focused element from window
      var windowFocused: CFTypeRef?
      let windowFocusResult = AXUIElementCopyAttributeValue(
        window as! AXUIElement,
        kAXFocusedUIElementAttribute as CFString,
        &windowFocused
      )
      
      if windowFocusResult == .success, let focused = windowFocused {
        debugPrint("✅ AccessibilityPaster: Got focused element via window", category: "AX")
        return (focused as! AXUIElement)
      }
      debugPrint("⚠️ AccessibilityPaster: Window focused element failed (error: \(windowFocusResult.rawValue))", category: "AX")
    } else {
      debugPrint("⚠️ AccessibilityPaster: Could not get focused window (error: \(windowResult.rawValue))", category: "AX")
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
    guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &range) else {
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
    
    // Get current value to append to (if desired) or just set
    var currentValue: CFTypeRef?
    let _ = AXUIElementCopyAttributeValue(
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
