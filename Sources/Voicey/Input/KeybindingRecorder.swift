import AppKit
import Carbon.HIToolbox
import KeyboardShortcuts
import SwiftUI

/// A local recorder that persists the shortcut through KeyboardShortcuts without
/// instantiating the package recorder view, which can assert if its resource
/// bundle is missing from a manually packaged app bundle.
struct KeybindingRecorderView: View {
  private static let minimumWidth: CGFloat = 150

  let name: KeyboardShortcuts.Name

  @State private var isRecording = false
  @State private var displayText = L10n.Hotkey.recordShortcut
  @State private var keyEventMonitor: Any?

  var body: some View {
    HStack {
      Button(action: startRecording) {
        Text(displayText)
          .foregroundStyle(isRecording ? .blue : .primary)
          .frame(minWidth: Self.minimumWidth, alignment: .leading)
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
      }
      .buttonStyle(.plain)

      if name.shortcut != nil {
        Button {
          clearBinding()
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
      }
    }
    .onAppear(perform: updateDisplayText)
    .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
      updateDisplayText()
    }
    .onDisappear(perform: stopRecording)
  }

  private func startRecording() {
    stopRecording()
    isRecording = true
    displayText = L10n.Hotkey.pressShortcut

    keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      guard isRecording else {
        return event
      }

      handleKeyEvent(event)
      return nil
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
    if event.keyCode == UInt16(kVK_Escape) {
      stopRecording()
      updateDisplayText()
      return
    }

    guard
      let shortcut = KeyboardShortcuts.Shortcut(event: event),
      !shortcut.modifiers.isEmpty
    else {
      return
    }

    name.shortcut = shortcut
    stopRecording()
    updateDisplayText()
  }

  private func clearBinding() {
    stopRecording()
    name.shortcut = nil
    updateDisplayText()
  }

  @MainActor
  private func updateDisplayText() {
    guard let shortcut = name.shortcut else {
      displayText = L10n.Hotkey.recordShortcut
      return
    }

    displayText = shortcut.description
  }
}

#Preview {
  KeybindingRecorderView(name: .toggleTranscription)
    .padding()
}
