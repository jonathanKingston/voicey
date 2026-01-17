import AppKit
import Carbon.HIToolbox
import KeyboardShortcuts
import SwiftUI
import os

final class AppDelegate: NSObject, NSApplicationDelegate {
  var statusBarController: StatusBarController?
  let appState = AppState()
  var transcriptionOverlay: TranscriptionOverlayController?

  // Dependencies
  private let dependencies: Dependencies

  // Keep strong reference to prevent deallocation while visible
  private var modelDownloadWindow: NSWindow?
  private var onboardingWindow: NSWindow?
  private var loadingWindow: NSWindow?

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

    // Check if setup is complete - show onboarding if anything is missing
    Task {
      let needsOnboarding = await checkIfOnboardingNeeded()

      await MainActor.run {
        if needsOnboarding {
          debugPrint("👋 Setup incomplete - showing onboarding", category: "STARTUP")
          showOnboarding()
        } else {
          debugPrint("✅ Setup complete - starting normally", category: "STARTUP")
          checkModelStatusAndPreload()
        }
      }
    }
  }

  /// Check if onboarding is needed (any required step incomplete)
  private func checkIfOnboardingNeeded() async -> Bool {
    // Check model
    ModelManager.shared.loadDownloadedModels()
    let hasModel = ModelManager.shared.hasDownloadedModel
    debugPrint("🔍 Has model: \(hasModel)", category: "STARTUP")

    // Check microphone
    let hasMicrophone = await dependencies.permissions.checkMicrophonePermission()
    debugPrint("🔍 Has microphone: \(hasMicrophone)", category: "STARTUP")

    // Check accessibility
    let hasAccessibility = dependencies.permissions.checkAccessibilityPermission()
    debugPrint("🔍 Has accessibility: \(hasAccessibility)", category: "STARTUP")

    // Need onboarding if any required step is missing
    let needsOnboarding = !hasModel || !hasMicrophone || !hasAccessibility
    debugPrint("🔍 Needs onboarding: \(needsOnboarding)", category: "STARTUP")

    return needsOnboarding
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
    onboardingWindow = nil
  }

  // MARK: - Onboarding

  private func showOnboarding() {
    let onboardingView = OnboardingView { [weak self] in
      AppLogger.general.info("Onboarding complete callback triggered")

      // Mark onboarding as complete
      SettingsManager.shared.hasCompletedOnboarding = true
      AppLogger.general.info("Marked onboarding as complete")

      // Close onboarding window
      self?.onboardingWindow?.close()
      self?.onboardingWindow = nil
      AppLogger.general.info("Closed onboarding window")

      // Update permission state silently (onboarding already handled prompts)
      Task {
        await self?.checkPermissionsSilently()
      }

      // Now start model loading (will show model downloader if needed)
      self?.checkModelStatusAndPreload()
    }

    let hostingController = NSHostingController(rootView: onboardingView)

    let window = NSWindow(contentViewController: hostingController)
    window.title = "Welcome to Voicey"
    // No close button - user must complete setup
    window.styleMask = [.titled]
    window.setContentSize(NSSize(width: 480, height: 720))
    window.center()

    // Prevent closing without completing
    window.isReleasedWhenClosed = false

    onboardingWindow = window

    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  private func setupComponents() {
    audioCaptureManager = AudioCaptureManager()
    audioCaptureManager?.delegate = self

    whisperEngine = WhisperEngine()
    whisperEngine?.onLoadingStateChanged = { [weak self] isLoading in
      if isLoading {
        self?.appState.transcriptionState = .loadingModel
      }
    }

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
    // Note: Global monitor requires accessibility permission
    escKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
      if event.keyCode == UInt16(kVK_Escape) {
        Task { @MainActor in
          // Cancel if in any active state (loading, recording, or processing)
          if self?.appState.transcriptionState.isActive == true {
            AppLogger.general.info(
              "ESC pressed - cancelling (state: \(String(describing: self?.appState.transcriptionState)))"
            )
            self?.cancelTranscription()
          }
        }
      }
    }

    // Local monitor for when app is focused (doesn't require accessibility)
    localEscKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      if event.keyCode == UInt16(kVK_Escape) {
        // Cancel if in any active state (loading, recording, or processing)
        if self?.appState.transcriptionState.isActive == true {
          AppLogger.general.info(
            "ESC pressed (local) - cancelling (state: \(String(describing: self?.appState.transcriptionState)))"
          )
          self?.cancelTranscription()
          return nil
        }
      }
      return event
    }
  }

  /// Check permissions silently - just log status, don't prompt
  private func checkPermissionsSilently() async {
    let micPermission = await dependencies.permissions.checkMicrophonePermission()
    let accessibilityPermission = dependencies.permissions.checkAccessibilityPermission()

    await MainActor.run {
      appState.hasAccessibilityPermission = accessibilityPermission
    }

    AppLogger.general.info(
      "Permission status - Microphone: \(micPermission), Accessibility: \(accessibilityPermission)")

    // Only warn if missing, don't prompt (user completed onboarding, they know)
    if !micPermission {
      AppLogger.general.warning("Microphone permission not granted")
    }
    if !accessibilityPermission {
      AppLogger.general.warning("Accessibility permission not granted - paste won't work")
    }
  }

  private func checkModelStatusAndPreload() {
    // Refresh model status
    ModelManager.shared.loadDownloadedModels()

    if ModelManager.shared.hasDownloadedModel {
      // Model is downloaded - load it into memory
      appState.modelStatus = .loading
      debugPrint("📦 Model downloaded, starting preload...", category: "MODEL")

      // Show loading window
      showLoadingWindow()

      // Preload the model
      Task {
        let startTime = CFAbsoluteTimeGetCurrent()
        await whisperEngine?.preloadModel()
        let loadTime = CFAbsoluteTimeGetCurrent() - startTime

        await MainActor.run {
          // Hide loading window
          self.hideLoadingWindow()

          if whisperEngine?.isModelLoaded == true {
            appState.modelStatus = .ready
            debugPrint("✅ Model ready in \(String(format: "%.1f", loadTime))s", category: "MODEL")
          } else {
            appState.modelStatus = .failed("Failed to load model")
            debugPrint("❌ Model preload failed", category: "MODEL")
          }
        }
      }
    } else if ModelManager.shared.isDownloading.values.contains(true) {
      // Download already in progress (started during onboarding)
      appState.modelStatus = .notDownloaded
      debugPrint("⏳ Model download in progress...", category: "MODEL")

      // Wait for download to complete, then preload
      Task {
        await waitForDownloadAndPreload()
      }
    } else {
      // No model and no download - show downloader (returning user scenario)
      appState.modelStatus = .notDownloaded
      debugPrint("📥 No model downloaded, opening downloader", category: "MODEL")
      Task { @MainActor in
        try? await Task.sleep(nanoseconds: 500_000_000)  // 0.5 seconds
        self.openModelDownloader()
      }
    }
  }

  // MARK: - Loading Window

  private func showLoadingWindow() {
    let loadingView = VStack(spacing: 16) {
      ProgressView()
        .scaleEffect(1.5)
      Text("Loading AI Model...")
        .font(.headline)
      Text("First launch may take 1-3 minutes for CoreML compilation")
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .padding(30)
    .frame(width: 300)

    let hostingController = NSHostingController(rootView: loadingView)

    let window = NSWindow(contentViewController: hostingController)
    window.title = "Voicey"
    window.styleMask = [.titled]
    window.setContentSize(NSSize(width: 300, height: 150))
    window.center()
    window.isReleasedWhenClosed = false

    loadingWindow = window

    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  private func hideLoadingWindow() {
    loadingWindow?.close()
    loadingWindow = nil
  }

  /// Wait for an in-progress download to complete, then preload the model
  private func waitForDownloadAndPreload() async {
    // Poll until download completes
    while ModelManager.shared.isDownloading.values.contains(true) {
      try? await Task.sleep(nanoseconds: 500_000_000)  // Check every 0.5s
    }

    // Refresh and check if we now have a model
    await MainActor.run {
      ModelManager.shared.loadDownloadedModels()
    }

    if ModelManager.shared.hasDownloadedModel {
      debugPrint("📦 Download complete, preloading model...", category: "MODEL")
      await MainActor.run {
        appState.modelStatus = .loading
        showLoadingWindow()
      }

      await whisperEngine?.preloadModel()

      await MainActor.run {
        hideLoadingWindow()

        if whisperEngine?.isModelLoaded == true {
          appState.modelStatus = .ready
          debugPrint("✅ Model ready!", category: "MODEL")
        } else {
          appState.modelStatus = .failed("Failed to load model")
        }
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
    // Check if model is loaded FIRST - this is critical
    guard whisperEngine?.isModelLoaded == true else {
      debugPrint("⚠️ Model not loaded yet - cannot record", category: "RECORD")

      // Show user feedback
      if appState.modelStatus.isLoading {
        debugPrint("⏳ Model is still loading...", category: "RECORD")
        // Could show a toast/notification here
      } else {
        debugPrint("❌ No model loaded - check model status", category: "RECORD")
      }
      return
    }

    // Refresh model status before recording
    ModelManager.shared.loadDownloadedModels()

    let selectedModel = SettingsManager.shared.selectedModel
    let downloadedModels = ModelManager.shared.downloadedModels
    AppLogger.general.info("startRecording: Selected model: \(selectedModel.rawValue)")
    AppLogger.general.info(
      "startRecording: Downloaded models: \(downloadedModels.map { $0.rawValue })")
    AppLogger.general.info(
      "startRecording: Is selected model downloaded? \(ModelManager.shared.isDownloaded(selectedModel))"
    )

    guard ModelManager.shared.hasDownloadedModel else {
      AppLogger.general.warning("startRecording: No models downloaded, opening downloader")
      openModelDownloader()
      return
    }

    // If selected model isn't downloaded, switch to first available model
    if !ModelManager.shared.isDownloaded(selectedModel),
      let firstDownloaded = downloadedModels.first
    {
      AppLogger.general.info(
        "startRecording: Selected model not available, switching to \(firstDownloaded.rawValue)")
      SettingsManager.shared.selectedModel = firstDownloaded
    }

    // Check if model is still loading - if so, show the overlay with loading state
    if appState.modelStatus.isLoading {
      AppLogger.audio.info("Model still loading, showing loading state...")
      appState.transcriptionState = .loadingModel
      showOverlay()

      // Wait for model to be ready, then start recording
      Task {
        // Poll until model is ready (with timeout)
        let deadline = Date().addingTimeInterval(30)  // 30 second timeout
        while appState.modelStatus.isLoading && Date() < deadline {
          try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
        }

        await MainActor.run {
          if appState.modelStatus.isReady {
            // Model is ready, now start recording
            self.beginRecordingAfterModelReady()
          } else {
            // Model failed to load or timed out
            self.hideOverlay()
            self.appState.transcriptionState = .error(message: "Model failed to load")
            self.dependencies.notifications.showTranscriptionError(
              "Model failed to load. Please try again.")
          }
        }
      }
      return
    }

    // Model is ready, start recording immediately
    beginRecordingAfterModelReady()
  }

  private func beginRecordingAfterModelReady() {
    debugPrint("🎙️ Starting recording...", category: "RECORD")
    AppLogger.audio.info("Starting recording...")

    // Save the current frontmost app BEFORE we show our overlay
    outputManager?.saveFrontmostApp()
    AppLogger.output.info(
      "Saved frontmost app: \(self.outputManager?.previousApp?.localizedName ?? "none")")

    appState.transcriptionState = .recording(startTime: Date())

    // Show overlay (or update it if already showing)
    showOverlay()

    // Start audio capture
    audioCaptureManager?.startCapture()

    // Update menubar
    statusBarController?.updateIcon(recording: true)
  }

  func stopRecording() {
    debugPrint("⏹️ Stopping recording...", category: "RECORD")
    AppLogger.audio.info("Stopping recording...")

    appState.transcriptionState = .processing

    // Stop audio capture and get buffer
    guard let audioBuffer = audioCaptureManager?.stopCapture() else {
      debugPrint("❌ No audio buffer!", category: "ERROR")
      AppLogger.audio.error("No audio buffer!")
      hideOverlay()
      appState.transcriptionState = .error(message: "No audio captured")
      return
    }

    let durationSec = Double(audioBuffer.count) / 16000.0
    debugPrint(
      "📊 Got \(audioBuffer.count) samples (~\(String(format: "%.1f", durationSec))s of audio)",
      category: "AUDIO")
    AppLogger.audio.info(
      "Got audio buffer with \(audioBuffer.count) samples (~\(String(format: "%.1f", durationSec))s)"
    )

    // Check minimum duration (0.5 seconds)
    if durationSec < 0.5 {
      debugPrint(
        "⚠️ Audio too short (\(String(format: "%.2f", durationSec))s), skipping", category: "AUDIO")
      AppLogger.audio.warning(
        "Audio too short (\(String(format: "%.2f", durationSec))s), skipping transcription")
      hideOverlay()
      appState.transcriptionState = .idle
      return
    }

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
      debugPrint("🔄 Starting transcription...", category: "TRANSCRIBE")
      AppLogger.transcription.info(
        "processTranscription: Starting with \(audioBuffer.count) samples")

      // Transcribe audio
      guard let result = try await whisperEngine?.transcribe(audioBuffer: audioBuffer) else {
        throw TranscriptionError.transcriptionFailed("No result from Whisper engine")
      }

      debugPrint("📝 Raw result: \"\(result.text)\"", category: "TRANSCRIBE")
      AppLogger.transcription.info("processTranscription: Got raw result: \"\(result.text)\"")

      // Post-process text
      let processedText = postProcessor?.process(result) ?? result.text
      debugPrint("✨ Processed text: \"\(processedText)\"", category: "TRANSCRIBE")
      AppLogger.transcription.info(
        "processTranscription: Processed text: \"\(processedText)\" (length: \(processedText.count))"
      )

      // Output text
      await MainActor.run {
        appState.transcriptionState = .completed(text: processedText)
        appState.lastTranscription = processedText

        // Check if we have any text to deliver
        if processedText.isEmpty {
          debugPrint("⚠️ No text to deliver (empty after processing)", category: "OUTPUT")
          AppLogger.transcription.warning(
            "processTranscription: No text to deliver (empty after processing)")
          self.hideOverlay()
          self.appState.transcriptionState = .idle
          return
        }

        debugPrint("📋 Copying to clipboard and pasting: \"\(processedText)\"", category: "OUTPUT")

        // Deliver text first (this will restore focus to previous app and paste)
        // Hide overlay AFTER a delay to not interfere with focus
        outputManager?.deliver(text: processedText) { [weak self] in
          debugPrint("✅ Paste complete", category: "OUTPUT")
          // Called after paste is complete
          self?.hideOverlay()
          // Reset to idle after delivery
          self?.appState.transcriptionState = .idle
        }
      }
    } catch {
      debugPrint("❌ Transcription error: \(error)", category: "ERROR")
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
      transcriptionOverlay?.onCancel = { [weak self] in
        self?.cancelTranscription()
      }
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
    window.title = "Voicey Settings"
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
      self?.appState.modelStatus = .loading
      Task { [weak self] in
        await self?.whisperEngine?.preloadModel()
        let isLoaded = self?.whisperEngine?.isModelLoaded == true
        await MainActor.run { [weak self] in
          if isLoaded {
            self?.appState.modelStatus = .ready
          } else {
            self?.appState.modelStatus = .failed("Failed to load model")
          }
        }
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
  static let toggleTranscription = Self(
    "toggleTranscription", default: .init(.v, modifiers: .control))
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
