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

  #if VOICEY_DIRECT_DISTRIBUTION
  // Sparkle updater for direct distribution builds
  private let sparkleUpdater = SparkleUpdater.shared
  #endif

  // Keep strong reference to prevent deallocation while visible
  private var modelDownloadWindow: NSWindow?
  private var loadingWindow: NSWindow?

  private var audioCaptureManager: AudioCaptureManager?
  private var whisperEngine: WhisperEngine?
  private var postProcessor: PostProcessor?
  private var outputManager: OutputManager?

  // The app that was frontmost when recording started (used for optional auto-paste)
  private var recordingTargetPID: pid_t?

  // The screen where recording was triggered (for overlay positioning)
  private var recordingTargetScreen: NSScreen?

  // ESC key monitors
  private var localEscKeyMonitor: Any?

  // Model upgrade lock - prevents recording during model swap
  private var isUpgradingModel = false

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

          // Log permission status while onboarding is visible (no prompts).
          Task {
            await self.checkPermissionsSilently()
          }

          // Preload in parallel, but avoid showing extra loading UI over onboarding.
          self.checkModelStatusAndPreload(showUI: false)
        } else {
          debugPrint("✅ Setup complete - starting normally", category: "STARTUP")
          // Log permission status on normal startup (no prompts)
          Task {
            await self.checkPermissionsSilently()
          }
          checkModelStatusAndPreload(showUI: true)
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

    // Check accessibility (required if auto-paste is enabled)
    let autoPasteEnabled = dependencies.settings.autoPasteEnabled
    let hasAccessibility = dependencies.permissions.checkAccessibilityPermission()
    let needsAccessibility = autoPasteEnabled && !hasAccessibility
    debugPrint("🔍 Has accessibility: \(hasAccessibility), auto-paste enabled: \(autoPasteEnabled)", category: "STARTUP")

    // Show onboarding if any required state is missing
    // This ensures users are guided through setup even if permissions were revoked
    let needsOnboarding = !hasModel || !hasMicrophone || needsAccessibility

    debugPrint("🔍 Needs onboarding: \(needsOnboarding)", category: "STARTUP")

    return needsOnboarding
  }

  func applicationWillTerminate(_ notification: Notification) {
    // Remove monitors
    if let monitor = localEscKeyMonitor {
      NSEvent.removeMonitor(monitor)
    }

    // Clean up
    transcriptionOverlay = nil
    modelDownloadWindow = nil
  }

  // MARK: - Onboarding (now uses Settings window with Setup tab)

  private func showOnboarding() {
    // Open settings window - the Setup tab provides onboarding experience
    openSettings()
    
    // Mark onboarding as shown
    SettingsManager.shared.hasCompletedOnboarding = true
    
    // Start model loading in background
    checkModelStatusAndPreload(showUI: false)
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

    // Handle performance issues
    whisperEngine?.onPerformanceIssue = { [weak self] metrics in
      self?.handlePerformanceIssue(metrics)
    }

    postProcessor = PostProcessor()
    outputManager = OutputManager()

    // Setup model upgrade callback
    ModelManager.shared.onUpgradeReady = { [weak self] model in
      self?.handleModelUpgradeReady(model)
    }
  }

  // MARK: - Performance Handling

  private func handlePerformanceIssue(_ metrics: PerformanceMetrics) {
    AppLogger.general.warning("Performance issue detected: \(metrics.description)")

    // Show notification with suggestion if available
    if let suggestion = metrics.suggestion {
      dependencies.notifications.showPerformanceWarning(suggestion)
    }
  }

  // MARK: - Model Upgrade Handling

  private func handleModelUpgradeReady(_ model: WhisperModel) {
    debugPrint("🎉 Quality model ready for upgrade: \(model.displayName)", category: "MODEL")
    tryPerformPendingUpgrade()
  }

  /// Try to perform a pending model upgrade if conditions are right
  private func tryPerformPendingUpgrade() {
    guard let pendingModel = ModelManager.shared.pendingUpgradeModel else {
      return
    }

    // Only upgrade if we're NOT already using the quality model
    let currentModel = SettingsManager.shared.selectedModel
    guard currentModel != ModelManager.qualityModel else {
      debugPrint("Not upgrading - already using \(currentModel.displayName)", category: "MODEL")
      ModelManager.shared.pendingUpgradeModel = nil
      return
    }

    // Check state and set lock atomically to prevent race with startRecording
    guard appState.transcriptionState == .idle && !isUpgradingModel else {
      debugPrint("⏳ Upgrade pending - waiting for transcription to complete...", category: "MODEL")
      return
    }

    // Lock to prevent recording during upgrade
    isUpgradingModel = true

    // Perform the upgrade
    performModelUpgrade(to: pendingModel)
  }

  private func performModelUpgrade(to model: WhisperModel) {
    let previousModel = SettingsManager.shared.selectedModel
    debugPrint("🔄 Upgrading from \(previousModel.displayName) → \(model.displayName)...", category: "MODEL")

    // DON'T set appState.modelStatus = .loading here - keep showing as ready so user knows they can still record
    // The isUpgradingModel flag will be released immediately so recording continues to work with the old model

    Task {
      // Release upgrade lock immediately - user can keep recording with old model during background load
      await MainActor.run {
        self.isUpgradingModel = false
      }

      // Load the new model in background (old model stays loaded and usable)
      do {
        debugPrint("📦 Background loading \(model.displayName) (you can keep recording with \(previousModel.displayName))...", category: "MODEL")
        let startTime = CFAbsoluteTimeGetCurrent()

        // Note: WhisperEngine.loadModel will unload the old model internally when loading a new one
        // We accept a brief interruption during the actual swap
        try await whisperEngine?.loadModel(variant: model.rawValue)
        let loadTime = CFAbsoluteTimeGetCurrent() - startTime

        // Update settings after successful load
        await MainActor.run {
          SettingsManager.shared.selectedModel = model
          appState.currentModel = model
          ModelManager.shared.pendingUpgradeModel = nil
          appState.modelStatus = .ready
          whisperEngine?.resetPerformanceTracking()
          debugPrint("✅ Upgraded to \(model.displayName) in \(String(format: "%.1f", loadTime))s!", category: "MODEL")
          dependencies.notifications.showModelUpgradeComplete(model: model)
        }
      } catch {
        await MainActor.run {
          // Upgrade failed - keep using old model
          ModelManager.shared.pendingUpgradeModel = nil
          appState.modelStatus = .ready  // Old model is still ready
          debugPrint("❌ Upgrade to \(model.displayName) failed: \(error). Continuing with \(previousModel.displayName)", category: "MODEL")
        }
      }
    }
  }

  private func setupHotkey() {
    KeyboardShortcuts.onKeyDown(for: .toggleTranscription) { [weak self] in
      self?.toggleTranscription()
    }
  }

  private func setupEscapeKeyMonitor() {
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
    let autoPasteEnabled = dependencies.settings.autoPasteEnabled
    let accessibilityPermission = dependencies.permissions.checkAccessibilityPermission()

    // Emit to both os.Logger and the debugPrint stream (so it shows up in `make run` output).
    AppLogger.general.info(
      "Permission status - Microphone: \(micPermission), AutoPaste: \(autoPasteEnabled), Accessibility: \(accessibilityPermission)"
    )
    debugPrint(
      "🔐 Permissions - Mic: \(micPermission), AutoPaste: \(autoPasteEnabled), Accessibility: \(accessibilityPermission)",
      category: "STARTUP"
    )

    if autoPasteEnabled && !accessibilityPermission {
      AppLogger.general.warning("Auto-paste enabled but Accessibility permission not granted")
      debugPrint(
        "⚠️ Auto-paste enabled but Accessibility not granted (will not paste)",
        category: "STARTUP"
      )
    }

    // Only warn if missing, don't prompt (user completed onboarding, they know)
    if !micPermission {
      AppLogger.general.warning("Microphone permission not granted")
      debugPrint("⚠️ Microphone permission not granted", category: "STARTUP")
    }
  }

  private func checkModelStatusAndPreload(showUI: Bool) {
    // Refresh model status
    ModelManager.shared.loadDownloadedModels()

    if ModelManager.shared.hasDownloadedModel {
      // Model is downloaded - load it into memory
      appState.modelStatus = .loading
      debugPrint("📦 Model downloaded, starting preload...", category: "MODEL")

      if showUI {
        // Show loading window
        showLoadingWindow()
      }

      // Preload the model
      Task {
        let startTime = CFAbsoluteTimeGetCurrent()
        await whisperEngine?.preloadModel()
        let loadTime = CFAbsoluteTimeGetCurrent() - startTime

        await MainActor.run {
          if showUI {
            // Hide loading window
            self.hideLoadingWindow()
          }

          if whisperEngine?.isModelLoaded == true {
            appState.modelStatus = .ready
            debugPrint("✅ Model ready in \(String(format: "%.1f", loadTime))s", category: "MODEL")

            // Start background upgrade if we're using the fast model
            self.startBackgroundUpgradeIfNeeded()
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
        await waitForDownloadAndPreload(showUI: showUI)
      }
    } else {
      // No model and no download - show downloader (returning user scenario)
      appState.modelStatus = .notDownloaded
      debugPrint("📥 No model downloaded, opening downloader", category: "MODEL")
      if showUI {
        Task { @MainActor in
          try? await Task.sleep(nanoseconds: 500_000_000)  // 0.5 seconds
          self.openModelDownloader()
        }
      }
    }
  }

  /// Start background download and prewarming of quality model if we're not already using it
  private func startBackgroundUpgradeIfNeeded() {
    let currentModel = SettingsManager.shared.selectedModel

    // Only auto-upgrade when using a fast model (base, tiny, small - English or multilingual).
    // If user manually selected a larger model, don't force-download the quality model.
    guard currentModel.isFastModel else {
      return
    }

    // Only start upgrade if NOT already using quality model
    guard currentModel != ModelManager.qualityModel else {
      debugPrint(
        "📦 Already using \(currentModel.displayName), no upgrade needed", category: "MODEL")
      return
    }

    // Check if quality model is already downloaded
    if ModelManager.shared.isDownloaded(ModelManager.qualityModel) {
      debugPrint("🔄 Quality model (\(ModelManager.qualityModel.displayName)) downloaded, starting background prewarm...", category: "MODEL")
    } else {
      debugPrint("📥 Starting background download of quality model...", category: "MODEL")
    }

    // Start the background upgrade process
    if let engine = whisperEngine {
      ModelManager.shared.startBackgroundUpgrade(engine: engine)
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
    window.styleMask = [.titled, .closable]  // Allow user to close/quit
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
  private func waitForDownloadAndPreload(showUI: Bool) async {
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
        if showUI {
          showLoadingWindow()
        }
      }

      await whisperEngine?.preloadModel()

      await MainActor.run {
        if showUI {
          hideLoadingWindow()
        }

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
      if appState.modelStatus.isLoading || isUpgradingModel {
        debugPrint("⏳ Model is loading/upgrading - please wait a moment...", category: "RECORD")
        dependencies.notifications.showModelLoading()
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
      let firstDownloaded = downloadedModels.first {
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

    // Capture the frontmost app BEFORE we show the overlay so we can return focus for auto-paste.
    let frontmost = NSWorkspace.shared.frontmostApplication
    if frontmost?.bundleIdentifier != Bundle.main.bundleIdentifier {
      recordingTargetPID = frontmost?.processIdentifier
      // Capture the screen where the frontmost window is located
      recordingTargetScreen = screenForApplication(frontmost)
    } else {
      recordingTargetPID = nil
      recordingTargetScreen = nil
    }

    appState.transcriptionState = .recording(startTime: Date())

    // Show overlay on the screen where the user was last interacting
    showOverlay()

    // Start audio capture
    audioCaptureManager?.startCapture()

    // Update menubar
    statusBarController?.updateIcon(recording: true)
  }

  /// Determine which screen contains the key window of the given application
  private func screenForApplication(_ app: NSRunningApplication?) -> NSScreen? {
    guard let app = app else { return nil }

    // Get the window list for all on-screen windows
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let windowInfoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
      return nil
    }

    // Find windows belonging to this application
    let appWindows = windowInfoList.filter { info in
      guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t else { return false }
      return ownerPID == app.processIdentifier
    }

    // Get the frontmost window (first in the list for this app, as list is front-to-back)
    guard let frontWindow = appWindows.first,
          let boundsDict = frontWindow[kCGWindowBounds as String] as? [String: CGFloat],
          let originX = boundsDict["X"],
          let originY = boundsDict["Y"],
          let width = boundsDict["Width"],
          let height = boundsDict["Height"] else {
      return nil
    }

    // Create the window rect (note: CGWindowBounds uses top-left origin)
    let windowRect = CGRect(x: originX, y: originY, width: width, height: height)

    // Find which screen contains the center of this window
    let windowCenter = CGPoint(x: windowRect.midX, y: windowRect.midY)

    // Convert from screen coordinates (top-left origin) to Cocoa coordinates (bottom-left origin)
    // to compare with NSScreen frames
    guard let mainScreen = NSScreen.screens.first else { return nil }
    let mainScreenHeight = mainScreen.frame.height
    let cocoaCenter = CGPoint(x: windowCenter.x, y: mainScreenHeight - windowCenter.y)

    // Find screen containing this point
    return NSScreen.screens.first { screen in
      screen.frame.contains(cocoaCenter)
    }
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
      // Check for pending model upgrade now that we're idle
      tryPerformPendingUpgrade()
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

    // Hide overlay
    hideOverlay()

    // Update menubar
    statusBarController?.updateIcon(recording: false)

    // Check for pending model upgrade now that we're idle
    tryPerformPendingUpgrade()
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
          // Check for pending model upgrade now that we're idle
          self.tryPerformPendingUpgrade()
          return
        }

        debugPrint("📋 Copying to clipboard: \"\(processedText)\"", category: "OUTPUT")

        // Deliver text to clipboard and optionally auto-paste
        outputManager?.deliver(text: processedText, targetPID: self.recordingTargetPID) { [weak self] in
          debugPrint("✅ Text copied to clipboard", category: "OUTPUT")
          self?.hideOverlay()
          self?.appState.transcriptionState = .idle
          self?.tryPerformPendingUpgrade()
        }

        // Clear targets after attempting output
        self.recordingTargetPID = nil
        self.recordingTargetScreen = nil
      }
    } catch {
      debugPrint("❌ Transcription error: \(error)", category: "ERROR")
      AppLogger.transcription.error("Transcription error: \(error)")
      await MainActor.run { [weak self] in
        self?.hideOverlay()
        self?.appState.transcriptionState = .error(message: error.localizedDescription)
        self?.dependencies.notifications.showTranscriptionError(error.localizedDescription)
        self?.tryPerformPendingUpgrade()
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
    // Show on the screen where the user was last interacting
    transcriptionOverlay?.show(on: recordingTargetScreen)
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
    window.setContentSize(NSSize(width: 500, height: 550))
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
        await MainActor.run { [weak self] in
          if self?.whisperEngine?.isModelLoaded == true {
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
