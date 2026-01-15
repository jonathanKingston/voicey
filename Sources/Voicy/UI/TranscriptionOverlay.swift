import SwiftUI
import AppKit

/// Controller for the transcription overlay window
final class TranscriptionOverlayController {
    private var window: NSPanel?
    private weak var appState: AppState?
    
    init(appState: AppState) {
        self.appState = appState
    }
    
    deinit {
        hide()
    }
    
    func show() {
        if window == nil {
            createWindow()
        }
        window?.orderFront(nil)
    }
    
    func hide() {
        window?.orderOut(nil)
    }
    
    private func createWindow() {
        guard let appState = appState else { return }
        
        let contentView = TranscriptionOverlayView()
            .environmentObject(appState)
        
        let hostingView = NSHostingView(rootView: contentView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 280, height: 70)
        
        // Use borderless window for fully custom appearance
        let panel = NSPanel(
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
        panel.hasShadow = false  // Disable window shadow, we'll use SwiftUI shadow
        panel.animationBehavior = .none
        
        // Center on main screen
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - hostingView.frame.width / 2
            let y = screenFrame.midY - hostingView.frame.height / 2 + 200
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
        
        window = panel
    }
}

/// SwiftUI view for the transcription overlay
struct TranscriptionOverlayView: View {
    @EnvironmentObject var appState: AppState
    
    private let cornerRadius: CGFloat = 16
    
    var body: some View {
        HStack(spacing: 14) {
            // Microphone icon
            ZStack {
                Circle()
                    .fill(Color.red.opacity(0.2))
                    .frame(width: 40, height: 40)
                
                Image(systemName: "mic.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.red)
            }
            
            // Waveform visualization
            WaveformView(level: appState.audioLevel)
                .frame(width: 100, height: 28)
            
            // Status text - fixed width to prevent wrapping
            Text(statusText)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(
            ZStack {
                // Solid dark background
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.85))
                
                // Blur overlay
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial.opacity(0.5))
            }
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
}

#Preview {
    TranscriptionOverlayView()
        .environmentObject({
            let state = AppState()
            state.transcriptionState = .recording(startTime: Date())
            state.audioLevel = 0.5
            return state
        }())
        .padding()
}
