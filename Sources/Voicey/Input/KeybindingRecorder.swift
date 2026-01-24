import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A view for recording custom keyboard shortcuts
struct KeybindingRecorderView: View {
  @Binding var keyCode: UInt32?
  @Binding var modifiers: UInt32

  @State private var isRecording = false
  @State private var displayText = "Click to record"
  @State private var keyEventMonitor: Any?

  var body: some View {
    HStack {
      Text(displayText)
        .foregroundStyle(isRecording ? .blue : .primary)
        .frame(minWidth: 150, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
          RoundedRectangle(cornerRadius: 6)
            .fill(isRecording ? Color.blue.opacity(0.1) : Color.gray.opacity(0.1))
            .overlay(
              RoundedRectangle(cornerRadius: 6)
                .stroke(isRecording ? Color.blue : Color.gray.opacity(0.3), lineWidth: 1)
            )
        )
        .onTapGesture {
          startRecording()
        }

      if keyCode != nil {
        Button {
          clearBinding()
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
      }
    }
    .onAppear {
      updateDisplayText()
    }
    .onDisappear {
      stopRecording()
    }
  }

  private func startRecording() {
    // Remove existing monitor first to prevent leaks
    stopRecording()

    isRecording = true
    displayText = "Press shortcut..."

    // Monitor for key events
    keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      if isRecording {
        handleKeyEvent(event)
        return nil  // Consume the event
      }
      return event
    }
  }

  private func stopRecording() {
    if let monitor = keyEventMonitor {
      NSEvent.removeMonitor(monitor)
      keyEventMonitor = nil
    }
    isRecording = false
  }

  private func handleKeyEvent(_ event: NSEvent) {
    // Escape cancels recording
    if event.keyCode == UInt16(kVK_Escape) {
      stopRecording()
      updateDisplayText()
      return
    }

    // Check for valid modifier
    let flags = event.modifierFlags
    guard
      flags.contains(.command) || flags.contains(.control) || flags.contains(.option)
        || flags.contains(.shift)
    else {
      // Require at least one modifier
      return
    }

    keyCode = UInt32(event.keyCode)
    modifiers = carbonModifiers(from: flags)
    stopRecording()
    updateDisplayText()
  }

  /// Convert Cocoa modifier flags to Carbon modifier flags
  private func carbonModifiers(from cocoaModifiers: NSEvent.ModifierFlags) -> UInt32 {
    var modifiers: UInt32 = 0
    if cocoaModifiers.contains(.command) { modifiers |= UInt32(cmdKey) }
    if cocoaModifiers.contains(.shift) { modifiers |= UInt32(shiftKey) }
    if cocoaModifiers.contains(.option) { modifiers |= UInt32(optionKey) }
    if cocoaModifiers.contains(.control) { modifiers |= UInt32(controlKey) }
    return modifiers
  }

  private func clearBinding() {
    stopRecording()
    keyCode = nil
    modifiers = 0
    updateDisplayText()
  }

  private func updateDisplayText() {
    guard let keyCode = keyCode else {
      displayText = "Click to record"
      return
    }

    displayText = formatShortcut(keyCode: keyCode, modifiers: modifiers)
  }

  private func formatShortcut(keyCode: UInt32, modifiers: UInt32) -> String {
    var parts: [String] = []

    if modifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
    if modifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
    if modifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
    if modifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }

    if let keyString = keyCodeToString(keyCode) {
      parts.append(keyString)
    }

    return parts.joined()
  }

  private func keyCodeToString(_ keyCode: UInt32) -> String? {
    let keyMap: [UInt32: String] = [
      UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_B): "B", UInt32(kVK_ANSI_C): "C",
      UInt32(kVK_ANSI_D): "D", UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_F): "F",
      UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_H): "H", UInt32(kVK_ANSI_I): "I",
      UInt32(kVK_ANSI_J): "J", UInt32(kVK_ANSI_K): "K", UInt32(kVK_ANSI_L): "L",
      UInt32(kVK_ANSI_M): "M", UInt32(kVK_ANSI_N): "N", UInt32(kVK_ANSI_O): "O",
      UInt32(kVK_ANSI_P): "P", UInt32(kVK_ANSI_Q): "Q", UInt32(kVK_ANSI_R): "R",
      UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_T): "T", UInt32(kVK_ANSI_U): "U",
      UInt32(kVK_ANSI_V): "V", UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_X): "X",
      UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_Z): "Z",
      UInt32(kVK_ANSI_0): "0", UInt32(kVK_ANSI_1): "1", UInt32(kVK_ANSI_2): "2",
      UInt32(kVK_ANSI_3): "3", UInt32(kVK_ANSI_4): "4", UInt32(kVK_ANSI_5): "5",
      UInt32(kVK_ANSI_6): "6", UInt32(kVK_ANSI_7): "7", UInt32(kVK_ANSI_8): "8",
      UInt32(kVK_ANSI_9): "9",
      UInt32(kVK_Return): "↩", UInt32(kVK_Tab): "⇥", UInt32(kVK_Space): "Space",
      UInt32(kVK_Delete): "⌫", UInt32(kVK_Escape): "⎋",
      UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3",
      UInt32(kVK_F4): "F4", UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6",
      UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8", UInt32(kVK_F9): "F9",
      UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
      UInt32(kVK_LeftArrow): "←", UInt32(kVK_RightArrow): "→",
      UInt32(kVK_UpArrow): "↑", UInt32(kVK_DownArrow): "↓"
    ]
    return keyMap[keyCode]
  }
}

#Preview {
  struct PreviewWrapper: View {
    @State var keyCode: UInt32? = UInt32(kVK_ANSI_C)
    @State var modifiers: UInt32 = UInt32(controlKey)

    var body: some View {
      KeybindingRecorderView(keyCode: $keyCode, modifiers: $modifiers)
        .padding()
    }
  }
  return PreviewWrapper()
}
