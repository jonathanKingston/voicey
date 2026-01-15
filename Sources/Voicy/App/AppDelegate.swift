import AppKit
import SwiftUI
import KeyboardShortcuts
import Carbon.HIToolbox
import os

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusBarController: StatusBarController?
    let appState = AppState()
    var transcriptionOverlay: TranscriptionOverlayController?
    
    // Dependencies
    private let dependencies: Dependencies
    
    // Keep strong reference to prevent deallocation while visible
    private var modelDownloadWindow: NSWindow?
    
    private var audioCaptureManager: AudioCaptureManager?
    private var whisperEngine: WhisperEngine?
    private var postProcessor: PostProcessor?
    private var outputManager: OutputManager?
    
    // ESC key monitors
    private var escKeyMonitor: Any?
    private var localEscKeyMonitor: Any?
    
    // MARK: - Initialization
    
    override init() {
        self.dependencies = Dependencies.shared
        super.init()
    }
    
    /// Testing initializer with custom dependencies
    init(dependencies: Dependencies) {
        self.dependencies = dependencies
        super.init()
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon by default
        if !dependencies.settings.showDockIcon {
            NSApp.setActivationPolicy(.accessory)
        }
        
        // Initialize components
        setupComponents()
        
        // Setup menubar
        statusBarController = StatusBarController(appState: appState, delegate: self)
        
        // Setup global hotkey
        setupHotkey()
        
        // Setup ESC key monitor
        setupEscapeKeyMonitor()
        
        // Check permissions
        Task {
            await checkPermissions()
        }
        
        // Check if model is downloaded and preload it
        checkModelStatusAndPreload()
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        // Remove monitors
        if let monitor = escKeyMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = localEscKeyMonitor {
            NSEvent.removeMonitor(monitor)
        }
        
        // Clean up
        transcriptionOverlay = nil
        modelDownloadWindow = nil
    }
    
    private func setupComponents() {
        audioCaptureManager = AudioCaptureManager()
        audioCaptureManager?.delegate = self
        
        whisperEngine = WhisperEngine()
        postProcessor = PostProcessor()
        outputManager = OutputManager()
    }
    
    private func setupHotkey() {
        KeyboardShortcuts.onKeyDown(for: .toggleTranscription) { [weak self] in
            self?.toggleTranscription()
        }
    }
    
    private func setupEscapeKeyMonitor() {
        // Global monitor for ESC key (works even when app is not focused)
        escKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == UInt16(kVK_Escape) {
                Task { @MainActor in
                    if self?.appState.isRecording == true {
                        AppLogger.general.info("ESC pressed - cancelling transcription")
                        self?.cancelTranscription()
                    }
                }
            }
        }
        
        // Local monitor for when app is focused
        localEscKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == UInt16(kVK_Escape) {
                if self?.appState.isRecording == true {
                    AppLogger.general.info("ESC pressed (local) - cancelling transcription")
                    self?.cancelTranscription()
                    return nil
                }
            }
            return event
        }
    }
    
    private func checkPermissions() async {
        // Check microphone permission
        let micPermission = await dependencies.permissions.checkMicrophonePermission()
        if !micPermission {
            _ = await dependencies.permissions.requestMicrophonePermission()
        }
        
        // Check accessibility permission - needed for paste
        let accessibilityPermission = dependencies.permissions.checkAccessibilityPermission()
        if !accessibilityPermission {
            AppLogger.general.warning("Accessibility permission not granted - paste won't work!")
            dependencies.permissions.promptForAccessibilityPermission()
        } else {
            AppLogger.general.info("Accessibility permission granted")
        }
    }
    
    private func checkModelStatusAndPreload() {
        // Refresh model status
        ModelManager.shared.loadDownloadedModels()
        
        if ModelManager.shared.hasDownloadedModel {
            // Preload the model in background
            Task {
                await whisperEngine?.preloadModel()
            }
        } else {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
                self.openModelDownloader()
            }
        }
    }
    
    // MARK: - Transcription Control
    
    func toggleTranscription() {
        if appState.isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }
    
    func startRecording() {
        // Refresh model status before recording
        ModelManager.shared.loadDownloadedModels()
        
        guard ModelManager.shared.hasDownloadedModel else {
            openModelDownloader()
            return
        }
        
        AppLogger.audio.info("Starting recording...")
        
        // Save the current frontmost app BEFORE we show our overlay
        outputManager?.saveFrontmostApp()
        AppLogger.output.info("Saved frontmost app: \(self.outputManager?.previousApp?.localizedName ?? "none")")
        
        appState.transcriptionState = .recording(startTime: Date())
        
        // Show overlay
        showOverlay()
        
        // Start audio capture
        audioCaptureManager?.startCapture()
        
        // Update menubar
        statusBarController?.updateIcon(recording: true)
    }
    
    func stopRecording() {
        AppLogger.audio.info("Stopping recording...")
        
        appState.transcriptionState = .processing
        
        // Stop audio capture and get buffer
        guard let audioBuffer = audioCaptureManager?.stopCapture() else {
            AppLogger.audio.error("No audio buffer!")
            hideOverlay()
            appState.transcriptionState = .error(message: "No audio captured")
            return
        }
        
        AppLogger.audio.info("Got audio buffer with \(audioBuffer.count) samples")
        
        // Update menubar
        statusBarController?.updateIcon(recording: false)
        
        // Process transcription
        Task {
            await processTranscription(audioBuffer: audioBuffer)
        }
    }
    
    func cancelTranscription() {
        AppLogger.general.info("Cancelling transcription...")
        
        appState.transcriptionState = .idle
        
        // Stop and discard audio
        _ = audioCaptureManager?.stopCapture()
        
        // Clear saved app
        outputManager?.previousApp = nil
        
        // Hide overlay
        hideOverlay()
        
        // Update menubar
        statusBarController?.updateIcon(recording: false)
    }
    
    private func processTranscription(audioBuffer: [Float]) async {
        do {
            // Transcribe audio
            guard let result = try await whisperEngine?.transcribe(audioBuffer: audioBuffer) else {
                throw TranscriptionError.transcriptionFailed("No result from Whisper engine")
            }
            
            // Post-process text
            let processedText = postProcessor?.process(result) ?? result.text
            AppLogger.transcription.info("Transcription result: \"\(processedText)\"")
            
            // Output text
            await MainActor.run {
                appState.transcriptionState = .completed(text: processedText)
                appState.lastTranscription = processedText
                
                // Deliver text first (this will restore focus to previous app and paste)
                // Hide overlay AFTER a delay to not interfere with focus
                outputManager?.deliver(text: processedText) { [weak self] in
                    // Called after paste is complete
                    self?.hideOverlay()
                    // Reset to idle after delivery
                    self?.appState.transcriptionState = .idle
                }
            }
        } catch {
            AppLogger.transcription.error("Transcription error: \(error)")
            await MainActor.run { [weak self] in
                self?.hideOverlay()
                self?.appState.transcriptionState = .error(message: error.localizedDescription)
                self?.outputManager?.previousApp = nil
                self?.dependencies.notifications.showTranscriptionError(error.localizedDescription)
            }
        }
    }
    
    // MARK: - Overlay
    
    private func showOverlay() {
        if transcriptionOverlay == nil {
            transcriptionOverlay = TranscriptionOverlayController(appState: appState)
        }
        transcriptionOverlay?.show()
    }
    
    private func hideOverlay() {
        transcriptionOverlay?.hide()
    }
    
    // MARK: - Public Actions
    
    func openSettings() {
        // Create settings window manually since SwiftUI Settings scene doesn't work well with accessory apps
        let settingsView = SettingsView()
            .environmentObject(appState)
        
        let hostingController = NSHostingController(rootView: settingsView)
        
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Voicy Settings"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 500, height: 400))
        window.center()
        
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    func openModelDownloader() {
        // Create model download view
        let downloadView = ModelDownloadView { [weak self] in
            self?.modelDownloadWindow?.close()
            self?.modelDownloadWindow = nil
            // Refresh model status and preload
            ModelManager.shared.loadDownloadedModels()
            
            // Preload the model after download
            Task {
                await self?.whisperEngine?.preloadModel()
            }
        }
        
        let hostingController = NSHostingController(rootView: downloadView)
        
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Download Models"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 450, height: 500))
        window.center()
        
        modelDownloadWindow = window
        
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }
    
    func quit() {
        NSApp.terminate(nil)
    }
}

// MARK: - AudioCaptureManagerDelegate

extension AppDelegate: AudioCaptureManagerDelegate {
    func audioCaptureManager(_ manager: AudioCaptureManager, didUpdateLevel level: Float) {
        Task { @MainActor in
            self.appState.audioLevel = level
        }
    }
}

// MARK: - Keyboard Shortcuts Extension

extension KeyboardShortcuts.Name {
    static let toggleTranscription = Self("toggleTranscription", default: .init(.v, modifiers: .control))
}

// MARK: - Errors

enum TranscriptionError: LocalizedError {
    case transcriptionFailed(String)
    case modelNotLoaded
    case audioCaptureFailed
    
    var errorDescription: String? {
        switch self {
        case .transcriptionFailed(let reason):
            return "Transcription failed: \(reason)"
        case .modelNotLoaded:
            return "No transcription model loaded"
        case .audioCaptureFailed:
            return "Failed to capture audio"
        }
    }
}
