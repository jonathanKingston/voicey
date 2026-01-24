import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Custom panel that can receive key events even when not key window
final class KeyablePanel: NSPanel {
  var onEscapePressed: (() -> Void)?

  override var canBecomeKey: Bool { true }

  override func keyDown(with event: NSEvent) {
    if event.keyCode == UInt16(kVK_Escape) {
      AppLogger.ui.info("ESC key detected in panel")
      onEscapePressed?()
    } else {
      super.keyDown(with: event)
    }
  }

  // Accept first responder to receive key events
  override var acceptsFirstResponder: Bool { true }
}

/// Controller for the transcription overlay window
final class TranscriptionOverlayController {
  private var window: KeyablePanel?
  private weak var appState: AppState?
  var onCancel: (() -> Void)?

  init(appState: AppState) {
    self.appState = appState
  }

  deinit {
    hide()
  }

  /// Show the overlay on the specified screen (or screen of the last interacted window)
  /// - Parameter targetScreen: The screen to show the overlay on. If nil, uses the screen
  ///   containing the mouse cursor as a fallback.
  func show(on targetScreen: NSScreen? = nil) {
    let screen = targetScreen ?? screenWithMouse() ?? NSScreen.main

    if window == nil {
      createWindow(on: screen)
    } else {
      // Reposition to the target screen each time we show
      positionWindow(on: screen)
    }
    window?.orderFront(nil)
    // Make the panel key to receive keyboard events
    window?.makeKey()
  }

  func hide() {
    window?.orderOut(nil)
  }

  /// Returns the screen containing the mouse cursor
  private func screenWithMouse() -> NSScreen? {
    let mouseLocation = NSEvent.mouseLocation
    return NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
  }

  /// Position the window centered horizontally, slightly above center vertically on the given screen
  private func positionWindow(on screen: NSScreen?) {
    guard let window = window, let screen = screen else { return }
    let screenFrame = screen.visibleFrame
    let windowFrame = window.frame
    let posX = screenFrame.midX - windowFrame.width / 2
    let posY = screenFrame.midY - windowFrame.height / 2 + 200
    window.setFrameOrigin(NSPoint(x: posX, y: posY))
  }

  private func createWindow(on screen: NSScreen?) {
    guard let appState = appState else { return }

    let contentView = TranscriptionOverlayView(onCancel: { [weak self] in
      self?.onCancel?()
    })
    .environmentObject(appState)

    let hostingView = NSHostingView(rootView: contentView)
    hostingView.frame = NSRect(x: 0, y: 0, width: 320, height: 70)

    // Use custom KeyablePanel that can receive key events
    let panel = KeyablePanel(
      contentRect: hostingView.frame,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )

    panel.contentView = hostingView
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.isMovableByWindowBackground = true
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = false
    panel.animationBehavior = .none

    // Connect ESC handler (backup if panel can receive keys)
    panel.onEscapePressed = { [weak self] in
      self?.onCancel?()
    }

    window = panel

    // Position on the target screen
    positionWindow(on: screen ?? NSScreen.main)
  }
}

/// SwiftUI view for the transcription overlay
struct TranscriptionOverlayView: View {
  @EnvironmentObject var appState: AppState
  var onCancel: (() -> Void)?

  private let cornerRadius: CGFloat = 16

  var body: some View {
    HStack(spacing: 14) {
      // Icon - changes based on state
      ZStack {
        Circle()
          .fill(iconBackgroundColor.opacity(0.2))
          .frame(width: 40, height: 40)

        if appState.transcriptionState.isLoadingModel || appState.transcriptionState.isProcessing {
          ProgressView()
            .scaleEffect(0.8)
            .progressViewStyle(CircularProgressViewStyle(tint: iconColor))
        } else {
          Image(systemName: iconName)
            .font(.system(size: 20))
            .foregroundStyle(iconColor)
        }
      }

      // Waveform visualization (only show when recording)
      if appState.transcriptionState.isRecording {
        WaveformView(level: appState.audioLevel)
          .frame(width: 100, height: 28)
      } else {
        // Placeholder for consistent sizing
        Rectangle()
          .fill(.clear)
          .frame(width: 100, height: 28)
      }

      // Status text
      Text(statusText)
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(.primary)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)

      // Cancel button
      Button {
        onCancel?()
      } label: {
        Image(systemName: "xmark.circle.fill")
          .font(.system(size: 20))
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
      .help("Cancel (ESC)")
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 16)
    .background(
      RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .fill(Color(nsColor: .windowBackgroundColor).opacity(0.95))
    )
    .overlay(
      RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
    )
    .shadow(color: .black.opacity(0.3), radius: 16, y: 6)
  }

  private var statusText: String {
    appState.transcriptionState.displayText
  }

  private var iconName: String {
    switch appState.transcriptionState {
    case .loadingModel:
      return "arrow.down.circle"
    case .recording:
      return "mic.fill"
    case .processing:
      return "waveform"
    case .completed:
      return "checkmark.circle.fill"
    case .error:
      return "exclamationmark.triangle.fill"
    case .idle:
      return "mic.fill"
    }
  }

  private var iconColor: Color {
    switch appState.transcriptionState {
    case .loadingModel:
      return .blue
    case .recording:
      return .red
    case .processing:
      return .orange
    case .completed:
      return .green
    case .error:
      return .red
    case .idle:
      return .gray
    }
  }

  private var iconBackgroundColor: Color {
    iconColor
  }
}

#Preview {
  TranscriptionOverlayView(onCancel: { print("Cancelled") })
    .environmentObject(
      {
        let state = AppState()
        state.transcriptionState = .recording(startTime: Date())
        state.audioLevel = 0.5
        return state
      }()
    )
    .padding()
}
