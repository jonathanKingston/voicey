import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Custom panel that can receive key events even when not key window
@MainActor
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
@MainActor
final class TranscriptionOverlayController {
  private var window: KeyablePanel?
  private weak var appState: AppState?
  var onCancel: (() -> Void)?

  init(appState: AppState) {
    self.appState = appState
  }

  deinit {}

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
    guard let window else { return }
    window.orderFront(nil)
    // Keep the panel as first responder so it receives Escape without AppKit
    // auto-highlighting the close button when the overlay becomes key.
    window.makeKey()
    _ = window.makeFirstResponder(window)
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
    // Room for material-backed overlay + fixed-width slots (avoids post-layout resize jitter).
    hostingView.frame = NSRect(x: 0, y: 0, width: 460, height: 92)

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
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  var onCancel: (() -> Void)?

  private let cornerRadius: CGFloat = 22
  /// Keeps status text from resizing the bar between recording, transcribing, and loading copy.
  private let statusLabelSlotWidth: CGFloat = 200

  var body: some View {
    HStack(alignment: .center, spacing: 14) {
      stateIcon

      activitySlot

      Text(statusText)
        .font(.system(size: 14, weight: .medium, design: .rounded))
        .foregroundStyle(.primary)
        .lineLimit(1)
        .truncationMode(.tail)
        .minimumScaleFactor(0.88)
        .frame(width: statusLabelSlotWidth, alignment: .leading)
        .multilineTextAlignment(.leading)

      Button {
        onCancel?()
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(.secondary)
          .frame(width: 28, height: 28)
          .background {
            Circle()
              .fill(.quaternary.opacity(colorScheme == .dark ? 0.35 : 0.5))
          }
          .overlay {
            Circle()
              .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.08), lineWidth: 0.5)
          }
      }
      .buttonStyle(.plain)
      .focusEffectDisabled()
      .help(L10n.Overlay.cancelHelp)
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 14)
    .frame(width: 454, alignment: .center)
    .background { glassBackground }
    .shadow(color: .black.opacity(colorScheme == .dark ? 0.45 : 0.18), radius: 28, y: 14)
    .shadow(color: .black.opacity(colorScheme == .dark ? 0.2 : 0.06), radius: 6, y: 2)
  }

  @ViewBuilder
  private var stateIcon: some View {
    ZStack {
      if reduceTransparency {
        Circle()
          .fill(iconBackgroundColor.opacity(0.22))
      } else {
        Circle()
          .fill(.ultraThinMaterial)
      }
      Circle()
        .strokeBorder(
          LinearGradient(
            colors: [
              Color.white.opacity(colorScheme == .dark ? 0.2 : 0.45),
              Color.white.opacity(0.04)
            ],
            startPoint: .top,
            endPoint: .bottom
          ),
          lineWidth: 0.75
        )

      Group {
        if appState.transcriptionState.isLoadingModel || appState.transcriptionState.isProcessing {
          ProgressView()
            .controlSize(.small)
            .scaleEffect(0.92)
            .progressViewStyle(.circular)
            .tint(iconColor)
        } else {
          Image(systemName: iconName)
            .font(.system(size: 19, weight: .semibold))
            .foregroundStyle(iconColor)
            .symbolRenderingMode(.hierarchical)
        }
      }
      .frame(width: 26, height: 26)
    }
    .frame(width: 40, height: 40)
    .accessibilityElement(children: .ignore)
  }

  /// Shared footprint for recording waveform vs processing / loading activity so the bar does not reflow.
  private var activitySlot: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.05))
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.06 : 0.12), lineWidth: 0.5)

      if appState.transcriptionState.isRecording {
        WaveformView(level: appState.audioLevel)
          .frame(width: 100, height: 26)
      }
    }
    .frame(width: 108, height: 32)
    .animation(.easeInOut(duration: 0.2), value: appState.transcriptionState.isRecording)
    .clipped()
  }

  @ViewBuilder
  private var glassBackground: some View {
    let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    ZStack {
      if reduceTransparency {
        shape.fill(Color(nsColor: .windowBackgroundColor).opacity(0.96))
      } else {
        shape.fill(.regularMaterial)
      }
      shape.strokeBorder(
        LinearGradient(
          colors: [
            Color.white.opacity(colorScheme == .dark ? 0.22 : 0.55),
            Color.white.opacity(colorScheme == .dark ? 0.06 : 0.12),
            Color.black.opacity(colorScheme == .dark ? 0.35 : 0.06)
          ],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        ),
        lineWidth: 1
      )
    }
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
