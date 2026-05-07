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
    let windowSize = TranscriptionOverlayView.hostWindowSize
    hostingView.frame = NSRect(x: 0, y: 0, width: windowSize.width, height: windowSize.height)
    hostingView.wantsLayer = true
    hostingView.layer?.masksToBounds = false

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

  /// Inset around the card so drop shadows are not clipped by the borderless panel bounds.
  private static let shadowPadding = EdgeInsets(top: 14, leading: 26, bottom: 34, trailing: 26)
  private static let cardWidth: CGFloat = 454
  private static let cardHeight: CGFloat = 68

  static var hostWindowSize: CGSize {
    CGSize(
      width: cardWidth + shadowPadding.leading + shadowPadding.trailing,
      height: cardHeight + shadowPadding.top + shadowPadding.bottom
    )
  }

  var body: some View {
    cardContent
      .padding(Self.shadowPadding)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
  }

  private var cardContent: some View {
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
    .frame(width: Self.cardWidth, height: Self.cardHeight, alignment: .center)
    .background { glassFill }
    .overlay { glassRim }
    .compositingGroup()
    .clipShape(cardShape)
    .shadow(color: .black.opacity(colorScheme == .dark ? 0.22 : 0.12), radius: 16, y: 8)
  }

  private var cardShape: RoundedRectangle {
    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
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
        if stateIconTintWashOpacity > 0 {
          Circle()
            .fill(iconBackgroundColor.opacity(stateIconTintWashOpacity))
        }
      }
      Circle()
        .strokeBorder(stateIconRimGradient, lineWidth: 0.75)

      Group {
        if appState.transcriptionState.isLoadingModel || appState.transcriptionState.isProcessing {
          ProgressView()
            .controlSize(.small)
            .scaleEffect(0.92)
            .progressViewStyle(.circular)
            .tint(iconColor.opacity(0.9))
        } else {
          Image(systemName: iconName)
            .font(.system(size: 19, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(iconForegroundPrimary, iconForegroundSecondary)
        }
      }
      .frame(width: 26, height: 26)
    }
    .frame(width: 40, height: 40)
    .accessibilityElement(children: .ignore)
  }

  /// Soft semantic wash on the frosted disc (recording reads as live without a flat badge).
  private var stateIconTintWashOpacity: Double {
    switch appState.transcriptionState {
    case .idle:
      return 0
    case .recording, .error:
      return colorScheme == .dark ? 0.22 : 0.16
    case .processing:
      return colorScheme == .dark ? 0.18 : 0.12
    case .loadingModel:
      return colorScheme == .dark ? 0.16 : 0.1
    case .completed:
      return colorScheme == .dark ? 0.14 : 0.1
    }
  }

  private var stateIconRimGradient: LinearGradient {
    let tint = iconBackgroundColor
    let tintStrength = stateIconTintWashOpacity > 0 ? 1.0 : 0.0
    return LinearGradient(
      colors: [
        Color.white.opacity(colorScheme == .dark ? 0.24 : 0.48),
        Color.white.opacity(0.06),
        tint.opacity((colorScheme == .dark ? 0.32 : 0.22) * tintStrength)
      ],
      startPoint: .top,
      endPoint: .bottom
    )
  }

  private var iconForegroundPrimary: Color {
    iconColor.opacity(colorScheme == .dark ? 0.92 : 0.88)
  }

  private var iconForegroundSecondary: Color {
    iconColor.opacity(colorScheme == .dark ? 0.52 : 0.58)
  }

  /// Shared footprint for recording waveform vs processing / loading activity so the bar does not reflow.
  private var activitySlot: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.05))
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.06 : 0.12), lineWidth: 0.5)

      activitySlotContent
        .frame(width: 100, height: 26)
    }
    .frame(width: 108, height: 32)
    .animation(.easeInOut(duration: 0.2), value: appState.transcriptionState.isRecording)
    .clipped()
  }

  @ViewBuilder
  private var activitySlotContent: some View {
    if appState.transcriptionState.isRecording {
      WaveformView(level: appState.audioLevel)
    } else if appState.transcriptionState.isProcessing,
              !appState.recordingWaveformEnvelope.isEmpty,
              let startedAt = appState.transcriptionProcessingStartedAt {
      CapturedWaveformProgressView(
        envelope: appState.recordingWaveformEnvelope,
        startedAt: startedAt,
        audioDuration: appState.recordingAudioDuration,
        estimatedRTF: appState.transcriptionProcessingEstimateRTF
      )
    } else if appState.transcriptionState.isProcessing || appState.transcriptionState.isLoadingModel {
      TranscriptionActivityPlaceholderView()
    }
  }

  @ViewBuilder
  private var glassFill: some View {
    if reduceTransparency {
      cardShape.fill(Color(nsColor: .windowBackgroundColor).opacity(0.96))
    } else {
      cardShape.fill(.regularMaterial)
    }
  }

  private var glassRim: some View {
    cardShape.strokeBorder(
      LinearGradient(
        colors: [
          Color.white.opacity(colorScheme == .dark ? 0.24 : 0.55),
          Color.white.opacity(colorScheme == .dark ? 0.1 : 0.18)
        ],
        startPoint: .top,
        endPoint: .bottom
      ),
      lineWidth: 0.75
    )
  }

  private var statusText: String {
    if appState.transcriptionState.isRecording && appState.isCatchingUpTranscription {
      return L10n.State.transcribing
    }

    return appState.transcriptionState.displayText
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
