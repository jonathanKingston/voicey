import AppKit
import Carbon.HIToolbox
import KeyboardShortcuts
import SwiftUI
import os
import VoiceyCore

final class AppDelegate: NSObject, NSApplicationDelegate {
  private static let automaticTerminationReason = "Voicey menubar app"
  private static let settingsWindowAutosaveName = "VoiceySettingsWindow"

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
  private var settingsWindow: NSWindow?

  private var audioCaptureManager: AudioCaptureManager?
  private var whisperEngine: WhisperEngine?
  private var graniteEngine: GraniteEngine?
  private var qwenEngine: QwenEngine?
  private var postProcessor: PostProcessor?
  private var outputManager: OutputManager?
  private var transcriptionCoordinator: TranscriptionCoordinator?
  private var coordinatorSpeechEngine: MacSpeechEngineRouter?
  private var coordinatorTextDeliverer: MacOutputTextDeliverer?
  private var activeTranscriptionRequestID: String?
  private var recordingStartTask: Task<Void, Never>?

  // The app that was frontmost when recording started (used for optional auto-paste)
  private var recordingTargetPID: pid_t?

  // The screen where recording was triggered (for overlay positioning)
  private var recordingTargetScreen: NSScreen?

  // ESC key monitors
  private var localEscKeyMonitor: Any?
  private var selectedModelObserver: Any?

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
    // Keep the menubar app alive even when it has no open windows.
    ProcessInfo.processInfo.disableAutomaticTermination(Self.automaticTerminationReason)

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

    // Keep runtime state in sync when the user changes models from settings.
    setupSelectedModelObserver()

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
    ProcessInfo.processInfo.enableAutomaticTermination(Self.automaticTerminationReason)

    if let observer = selectedModelObserver {
      NotificationCenter.default.removeObserver(observer)
    }

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

    // Start model loading in background
    checkModelStatusAndPreload(showUI: false)
  }

  /// Whether the active engine (Whisper or Granite) has a model loaded
  private var isActiveEngineLoaded: Bool {
    let selectedModel = SettingsManager.shared.selectedModel
    switch selectedModel.backendKind {
    case .granitePython:
      return graniteEngine?.isModelLoaded == true
    case .qwenMLX:
      return qwenEngine?.isModelLoaded == true
    case .whisperKit:
      return whisperEngine?.isModelLoaded == true
    }
  }

  private func fallbackOrder(preferredBackend: SpeechBackendKind? = nil) -> [SpeechModel] {
    let baseOrder: [SpeechModel] = [
      ModelManager.defaultModel,
      .qwen3Large, .qwen3Small, .graniteSpeech,
      .largeTurbo, .large, .distilLarge, .small, .smallEn, .base, .baseEn, .tiny, .tinyEn
    ]

    var ordered: [SpeechModel] = []
    let prioritized = preferredBackend == nil ? baseOrder : baseOrder.filter { $0.backendKind == preferredBackend }
    let remainder = preferredBackend == nil ? [] : baseOrder.filter { $0.backendKind != preferredBackend }

    for model in prioritized + remainder {
      if !ordered.contains(model) {
        ordered.append(model)
      }
    }
    return ordered
  }

  /// Best available fallback model when the selected backend cannot load.
  private func bestAvailableFallback(excluding failedBackend: SpeechBackendKind) -> SpeechModel? {
    let downloaded = ModelManager.shared.downloadedModels
    for model in fallbackOrder() {
      if model.backendKind != failedBackend && downloaded.contains(model) {
        return model
      }
    }
    return downloaded.first(where: { $0.backendKind != failedBackend })
  }

  @MainActor
  private func preloadSelectedModel() async -> Bool {
    let selectedModel = SettingsManager.shared.selectedModel

    switch selectedModel.backendKind {
    case .granitePython:
      await graniteEngine?.preloadModel()
      return graniteEngine?.isModelLoaded == true
    case .qwenMLX:
      await qwenEngine?.preloadModel()
      return qwenEngine?.isModelLoaded == true
    case .whisperKit:
      await whisperEngine?.preloadModel()
      return whisperEngine?.isModelLoaded == true
    }
  }

  /// Preload selected model. If a backend fails to load, fall back to another downloaded backend automatically.
  @MainActor
  private func preloadSelectedModelWithFallback() async -> Bool {
    let selectedModel = SettingsManager.shared.selectedModel

    if await preloadSelectedModel() {
      return true
    }

    if let fallback = bestAvailableFallback(excluding: selectedModel.backendKind) {
      debugPrint(
        "⚠️ \(selectedModel.displayName) unavailable, falling back to \(fallback.displayName)",
        category: "MODEL"
      )
      SettingsManager.shared.selectedModel = fallback
      appState.currentModel = fallback

      switch fallback.backendKind {
      case .granitePython:
        await graniteEngine?.preloadModel()
        return graniteEngine?.isModelLoaded == true
      case .qwenMLX:
        await qwenEngine?.preloadModel()
        return qwenEngine?.isModelLoaded == true
      case .whisperKit:
        await whisperEngine?.preloadModel()
        return whisperEngine?.isModelLoaded == true
      }
    }

    return false
  }

  private func setupSelectedModelObserver() {
    selectedModelObserver = NotificationCenter.default.addObserver(
      forName: .voiceySelectedModelDidChange,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      guard let self, let model = notification.object as? SpeechModel else { return }
      Task { @MainActor in
        await self.handleSelectedModelChange(model)
      }
    }
  }

  @MainActor
  private func handleSelectedModelChange(_ model: SpeechModel) async {
    appState.currentModel = model
    coordinatorSpeechEngine?.selectModel(model)
    unloadInactiveEngines(keeping: model.backendKind)
    ModelManager.shared.loadDownloadedModels()

    guard ModelManager.shared.isDownloaded(model) else {
      appState.modelStatus = .notDownloaded
      return
    }

    appState.modelStatus = .loading
    let preloadSucceeded = await preloadSelectedModel()
    if preloadSucceeded && isActiveEngineLoaded {
      appState.modelStatus = .ready
    } else {
      appState.modelStatus = .failed("Failed to load model")
    }
  }

  private func unloadInactiveEngines(keeping backend: SpeechBackendKind) {
    if backend != .whisperKit {
      whisperEngine?.unloadModel()
    }
    if backend != .granitePython {
      graniteEngine?.unloadModel()
    }
    if backend != .qwenMLX {
      qwenEngine?.unloadModel()
    }
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

    graniteEngine = GraniteEngine()
    graniteEngine?.onLoadingStateChanged = { [weak self] isLoading in
      if isLoading {
        self?.appState.transcriptionState = .loadingModel
      }
    }
    graniteEngine?.onPerformanceIssue = { [weak self] metrics in
      self?.handlePerformanceIssue(metrics)
    }

    qwenEngine = QwenEngine()
    qwenEngine?.onLoadingStateChanged = { [weak self] isLoading in
      if isLoading {
        self?.appState.transcriptionState = .loadingModel
      }
    }
    qwenEngine?.onPerformanceIssue = { [weak self] metrics in
      self?.handlePerformanceIssue(metrics)
    }

    postProcessor = PostProcessor()
    outputManager = OutputManager()
    if
      let audioCaptureManager,
      let whisperEngine,
      let graniteEngine,
      let qwenEngine,
      let postProcessor,
      let outputManager
    {
      let speechRouter = MacSpeechEngineRouter(
        whisperEngine: whisperEngine,
        graniteEngine: graniteEngine,
        qwenEngine: qwenEngine,
        postProcessor: postProcessor
      )
      let textDeliverer = MacOutputTextDeliverer(outputManager: outputManager)
      speechRouter.selectModel(SettingsManager.shared.selectedModel)
      self.coordinatorSpeechEngine = speechRouter
      self.coordinatorTextDeliverer = textDeliverer
      self.transcriptionCoordinator = TranscriptionCoordinator(
        audioCapturer: audioCaptureManager,
        speechEngine: speechRouter,
        textDeliverer: textDeliverer
      )
    }

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

  private func handleModelUpgradeReady(_ model: SpeechModel) {
    debugPrint("🎉 Model ready for upgrade: \(model.displayName)", category: "MODEL")
    tryPerformPendingUpgrade()
  }

  /// Try to perform a pending model upgrade if conditions are right
  private func tryPerformPendingUpgrade() {
    guard let pendingModel = ModelManager.shared.pendingUpgradeModel else {
      return
    }

    // Only upgrade if we're NOT already using the target model.
    let currentModel = SettingsManager.shared.selectedModel
    guard currentModel != pendingModel else {
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
      checkForDefaultModelUpdate()

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
        let preloadSucceeded = await self.preloadSelectedModelWithFallback()
        let loadTime = CFAbsoluteTimeGetCurrent() - startTime

        await MainActor.run {
          if showUI {
            // Hide loading window
            self.hideLoadingWindow()
          }

          if preloadSucceeded && self.isActiveEngineLoaded {
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

  /// If the app's recommended default model changed, migrate users who are still on the old default.
  private func checkForDefaultModelUpdate() {
    let targetModel = ModelManager.defaultModel
    let currentModel = dependencies.settings.selectedModel
    let lastSeenDefault = dependencies.settings.lastSeenDefaultModel
    let lastAppliedDefault = dependencies.settings.lastAppliedDefaultModel

    guard lastSeenDefault != targetModel.rawValue else {
      return
    }

    // Record the new recommendation immediately so we don't repeatedly trigger the same migration path.
    dependencies.settings.lastSeenDefaultModel = targetModel.rawValue

    // Only auto-switch users who are still on what we last auto-applied as "default".
    // If they manually picked another model, preserve that choice.
    if let lastAppliedDefault, currentModel.rawValue != lastAppliedDefault {
      return
    }

    if currentModel == targetModel {
      dependencies.settings.lastAppliedDefaultModel = targetModel.rawValue
      return
    }

    // If the target is already local, queue a switch when idle.
    if ModelManager.shared.isDownloaded(targetModel) {
      dependencies.settings.lastAppliedDefaultModel = targetModel.rawValue
      debugPrint(
        "🔄 Default model changed to \(targetModel.displayName); scheduling switch",
        category: "MODEL"
      )
      ModelManager.shared.pendingUpgradeModel = targetModel
      tryPerformPendingUpgrade()
      return
    }

    debugPrint(
      "📥 Default model changed to \(targetModel.displayName); downloading then scheduling switch",
      category: "MODEL"
    )
    ModelManager.shared.downloadModel(targetModel)

    Task {
      while ModelManager.shared.isDownloading[targetModel] == true {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
      }

      guard ModelManager.shared.isDownloaded(targetModel) else {
        AppLogger.model.warning(
          "Default model update download failed: \(targetModel.displayName)"
        )
        return
      }

      await MainActor.run {
        dependencies.settings.lastAppliedDefaultModel = targetModel.rawValue
        ModelManager.shared.pendingUpgradeModel = targetModel
        tryPerformPendingUpgrade()
      }
    }
  }

  /// Upgrade to a target model once it is ready.
  private func performModelUpgrade(to model: SpeechModel) {
    let previousModel = SettingsManager.shared.selectedModel
    debugPrint("🔄 Upgrading from \(previousModel.displayName) → \(model.displayName)...", category: "MODEL")

    Task {
      // Release upgrade lock immediately so normal recording can continue while loading in background.
      await MainActor.run {
        self.isUpgradingModel = false
      }

      do {
        debugPrint(
          "📦 Background loading \(model.displayName) (you can keep recording with \(previousModel.displayName))...",
          category: "MODEL")
        let startTime = CFAbsoluteTimeGetCurrent()

        switch model.backendKind {
        case .granitePython:
          // Granite preload checks runtime dependencies and marks model readiness.
          await MainActor.run {
            SettingsManager.shared.selectedModel = model
            appState.currentModel = model
          }
          await graniteEngine?.preloadModel()
          guard graniteEngine?.isModelLoaded == true else {
            throw GraniteError.modelNotReady
          }
        case .qwenMLX:
          guard let qwenEngine else {
            throw QwenError.modelNotReady
          }
          try await qwenEngine.loadModel(variant: model.rawValue)
          guard qwenEngine.isModelLoaded else {
            throw QwenError.modelNotReady
          }
        case .whisperKit:
          // WhisperEngine.loadModel unloads/reloads internally.
          guard let whisperEngine else {
            throw WhisperError.noModelLoaded
          }
          try await whisperEngine.loadModel(variant: model.rawValue)
          guard whisperEngine.isModelLoaded else {
            throw WhisperError.noModelLoaded
          }
        }

        let loadTime = CFAbsoluteTimeGetCurrent() - startTime

        await MainActor.run {
          SettingsManager.shared.selectedModel = model
          appState.currentModel = model
          ModelManager.shared.pendingUpgradeModel = nil
          appState.modelStatus = .ready
          whisperEngine?.resetPerformanceTracking()
          graniteEngine?.resetPerformanceTracking()
          qwenEngine?.resetPerformanceTracking()
          debugPrint("✅ Upgraded to \(model.displayName) in \(String(format: "%.1f", loadTime))s!", category: "MODEL")
          dependencies.notifications.showModelUpgradeComplete(model: model)
        }
      } catch {
        await MainActor.run {
          // Upgrade failed - continue using previous model.
          SettingsManager.shared.selectedModel = previousModel
          appState.currentModel = previousModel
          ModelManager.shared.pendingUpgradeModel = nil
          appState.modelStatus = .ready
          debugPrint(
            "❌ Upgrade to \(model.displayName) failed: \(error). Continuing with \(previousModel.displayName)",
            category: "MODEL")
        }
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

      let success = await preloadSelectedModelWithFallback()

      await MainActor.run {
        if showUI {
          hideLoadingWindow()
        }

        if success && self.isActiveEngineLoaded {
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
    // Refresh model status before recording
    ModelManager.shared.loadDownloadedModels()

    var selectedModel = SettingsManager.shared.selectedModel
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

    // If selected model isn't downloaded, switch to the best deterministic fallback.
    if !ModelManager.shared.isDownloaded(selectedModel),
      let fallbackModel = fallbackOrder(preferredBackend: selectedModel.backendKind).first(where: {
        downloadedModels.contains($0)
      }) {
      AppLogger.general.info(
        "startRecording: Selected model not available, switching to \(fallbackModel.rawValue)")
      SettingsManager.shared.selectedModel = fallbackModel
      appState.currentModel = fallbackModel
      selectedModel = fallbackModel
    }
    coordinatorSpeechEngine?.selectModel(selectedModel)

    // If the newly selected backend is not loaded yet, load it before recording.
    if !isActiveEngineLoaded {
      debugPrint("⏳ Selected model is not loaded yet - loading now...", category: "RECORD")
      appState.modelStatus = .loading
      appState.transcriptionState = .loadingModel
      showOverlay()

      Task {
        let preloadSucceeded = await self.preloadSelectedModel()

        await MainActor.run {
          if preloadSucceeded && self.isActiveEngineLoaded {
            self.appState.modelStatus = .ready
            self.beginRecordingAfterModelReady()
          } else {
            self.hideOverlay()
            self.appState.modelStatus = .failed("Failed to load model")
            self.appState.transcriptionState = .error(message: "Model failed to load")
            self.dependencies.notifications.showTranscriptionError(
              "Model failed to load. Please try again.")
          }
        }
      }
      return
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

    guard
      let transcriptionCoordinator,
      let coordinatorTextDeliverer,
      let audioCaptureManager
    else {
      hideOverlay()
      appState.transcriptionState = .error(message: "Transcription pipeline unavailable")
      dependencies.notifications.showTranscriptionError("Transcription pipeline unavailable")
      return
    }

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

    coordinatorTextDeliverer.setTargetPID(recordingTargetPID)
    let selectedModel = SettingsManager.shared.selectedModel
    audioCaptureManager.configureTrailingTrimHeuristic(enabled: !selectedModel.isGraniteModel)
    activeTranscriptionRequestID = UUID().uuidString
    appState.transcriptionState = .recording(startTime: Date())

    // Show overlay on the screen where the user was last interacting
    showOverlay()
    statusBarController?.updateIcon(recording: true)

    guard let requestID = activeTranscriptionRequestID else {
      hideOverlay()
      appState.transcriptionState = .error(message: "Missing transcription request context")
      dependencies.notifications.showTranscriptionError("Missing transcription request context")
      statusBarController?.updateIcon(recording: false)
      return
    }

    recordingStartTask = Task { @MainActor [weak self] in
      guard let self else { return }
      defer { recordingStartTask = nil }
      do {
        try await transcriptionCoordinator.startRecording(requestID: requestID)
        if case .recording(let startedAt) = await transcriptionCoordinator.state {
          appState.transcriptionState = .recording(startTime: startedAt)
        } else {
          appState.transcriptionState = .recording(startTime: Date())
        }
      } catch {
        debugPrint("❌ Failed to start recording: \(error)", category: "ERROR")
        AppLogger.audio.error("Failed to start recording: \(error)")
        hideOverlay()
        appState.transcriptionState = .error(message: error.localizedDescription)
        dependencies.notifications.showTranscriptionError(error.localizedDescription)
        statusBarController?.updateIcon(recording: false)
        finalizeTranscriptionCycle()
      }
    }
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
    statusBarController?.updateIcon(recording: false)

    guard let transcriptionCoordinator else {
      hideOverlay()
      appState.transcriptionState = .error(message: "Transcription coordinator unavailable")
      dependencies.notifications.showTranscriptionError("Transcription coordinator unavailable")
      finalizeTranscriptionCycle()
      return
    }

    Task { @MainActor [weak self] in
      guard let self else { return }
      if let recordingStartTask {
        await recordingStartTask.value
      }
      guard activeTranscriptionRequestID != nil else {
        return
      }
      appState.transcriptionState = .processing

      do {
        try await transcriptionCoordinator.stopRecording()
        let coordinatorState = await transcriptionCoordinator.state

        switch coordinatorState {
        case .completed(let text, _):
          appState.transcriptionState = .completed(text: text)
          appState.lastTranscription = text
          hideOverlay()
          appState.transcriptionState = .idle
        case .failed(let message):
          hideOverlay()
          appState.transcriptionState = .error(message: message)
          dependencies.notifications.showTranscriptionError(message)
        default:
          hideOverlay()
          appState.transcriptionState = .idle
        }

        finalizeTranscriptionCycle()
      } catch {
        await transcriptionCoordinator.cancel()

        if let speechError = error as? MacSpeechEngineRouterError,
           case .audioTooShort(let duration) = speechError
        {
          debugPrint(
            "⚠️ Audio too short (\(String(format: "%.2f", duration))s), skipping",
            category: "AUDIO"
          )
          AppLogger.audio.warning(
            "Audio too short (\(String(format: "%.2f", duration))s), skipping transcription"
          )
          hideOverlay()
          appState.transcriptionState = .idle
          finalizeTranscriptionCycle()
          return
        }

        if let coordinatorError = error as? TranscriptionCoordinatorError,
           coordinatorError == .emptyTranscription
        {
          debugPrint("⚠️ No text to deliver (empty after processing)", category: "OUTPUT")
          AppLogger.transcription.warning(
            "No text to deliver (empty/whitespace after processing)"
          )
          hideOverlay()
          appState.transcriptionState = .idle
          finalizeTranscriptionCycle()
          return
        }

        if let captureError = error as? AudioCaptureManagerError,
           captureError == .noAudioCaptured
        {
          debugPrint("❌ No audio buffer!", category: "ERROR")
          AppLogger.audio.error("No audio buffer!")
          hideOverlay()
          appState.transcriptionState = .error(message: "No audio captured")
          finalizeTranscriptionCycle()
          return
        }

        debugPrint("❌ Transcription error: \(error)", category: "ERROR")
        AppLogger.transcription.error("Transcription error: \(error)")
        hideOverlay()
        appState.transcriptionState = .error(message: error.localizedDescription)
        dependencies.notifications.showTranscriptionError(error.localizedDescription)
        finalizeTranscriptionCycle()
      }
    }
  }

  func cancelTranscription() {
    AppLogger.general.info("Cancelling transcription...")

    Task { @MainActor [weak self] in
      guard let self else { return }
      recordingStartTask?.cancel()
      recordingStartTask = nil
      await transcriptionCoordinator?.cancel()
      appState.transcriptionState = .idle
      hideOverlay()
      statusBarController?.updateIcon(recording: false)
      finalizeTranscriptionCycle()
    }
  }

  private func finalizeTranscriptionCycle() {
    recordingStartTask = nil
    recordingTargetPID = nil
    recordingTargetScreen = nil
    activeTranscriptionRequestID = nil
    coordinatorTextDeliverer?.clearTargetPID()
    tryPerformPendingUpgrade()
  }

  // MARK: - Overlay

  private func showOverlay() {
    Task { @MainActor [weak self] in
      guard let self else { return }
      if transcriptionOverlay == nil {
        transcriptionOverlay = TranscriptionOverlayController(appState: appState)
        transcriptionOverlay?.onCancel = { [weak self] in
          self?.cancelTranscription()
        }
      }
      transcriptionOverlay?.show(on: recordingTargetScreen)
    }
  }

  private func hideOverlay() {
    Task { @MainActor [weak self] in
      self?.transcriptionOverlay?.hide()
    }
  }

  // MARK: - Public Actions

  func openSettings() {
    // Reuse existing settings window if it's still open
    if let existingWindow = settingsWindow, existingWindow.isVisible {
      existingWindow.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      return
    }

    // Create settings window manually since SwiftUI Settings scene doesn't work well with accessory apps
    let settingsView = SettingsView()
      .environmentObject(appState)

    let hostingController = NSHostingController(rootView: settingsView)

    let window = NSWindow(contentViewController: hostingController)
    window.title = "Voicey Settings"
    window.styleMask = [.titled, .closable]
    window.setContentSize(NSSize(width: 500, height: 550))
    if !window.setFrameUsingName(Self.settingsWindowAutosaveName) {
      positionWindow(window, centeredOn: screenWithMouse() ?? NSScreen.main)
    }
    window.setFrameAutosaveName(Self.settingsWindowAutosaveName)

    settingsWindow = window

    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  /// Returns the screen that currently contains the mouse cursor.
  private func screenWithMouse() -> NSScreen? {
    let mouseLocation = NSEvent.mouseLocation
    return NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
  }

  /// Centers a window on the given screen and snaps origin to physical pixels.
  private func positionWindow(_ window: NSWindow, centeredOn screen: NSScreen?) {
    guard let screen else {
      window.center()
      return
    }

    let visibleFrame = screen.visibleFrame
    let windowSize = window.frame.size
    let rawOrigin = NSPoint(
      x: visibleFrame.midX - windowSize.width / 2,
      y: visibleFrame.midY - windowSize.height / 2
    )
    let scale = screen.backingScaleFactor
    let snappedOrigin = NSPoint(
      x: (rawOrigin.x * scale).rounded() / scale,
      y: (rawOrigin.y * scale).rounded() / scale
    )

    window.setFrameOrigin(snappedOrigin)
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
        let selectedModel = SettingsManager.shared.selectedModel
        switch selectedModel.backendKind {
        case .granitePython:
          await self?.graniteEngine?.preloadModel()
        case .qwenMLX:
          await self?.qwenEngine?.preloadModel()
        case .whisperKit:
          await self?.whisperEngine?.preloadModel()
        }
        await MainActor.run { [weak self] in
          if self?.isActiveEngineLoaded == true {
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

enum MacSpeechEngineRouterError: LocalizedError {
  case audioTooShort(duration: TimeInterval)
  case invalidModelIdentifier(String)

  var errorDescription: String? {
    switch self {
    case .audioTooShort(let duration):
      return "Audio too short (\(String(format: "%.2f", duration))s)"
    case .invalidModelIdentifier(let identifier):
      return "Unsupported model identifier: \(identifier)"
    }
  }
}

final class MacSpeechEngineRouter: @unchecked Sendable, SpeechEngine {
  private static let minimumAudioDurationSeconds: TimeInterval = 0.5
  private static let targetSampleRate: Double = 16_000

  private let whisperEngine: WhisperEngine
  private let graniteEngine: GraniteEngine
  private let qwenEngine: QwenEngine
  private let postProcessor: PostProcessor
  private let modelLock = NSLock()

  private var selectedModel: SpeechModel = SettingsManager.shared.selectedModel

  init(
    whisperEngine: WhisperEngine,
    graniteEngine: GraniteEngine,
    qwenEngine: QwenEngine,
    postProcessor: PostProcessor
  ) {
    self.whisperEngine = whisperEngine
    self.graniteEngine = graniteEngine
    self.qwenEngine = qwenEngine
    self.postProcessor = postProcessor
  }

  var identifier: String {
    currentModel.rawValue
  }

  var isReady: Bool {
    switch currentModel.backendKind {
    case .granitePython:
      return graniteEngine.isModelLoaded
    case .qwenMLX:
      return qwenEngine.isModelLoaded
    case .whisperKit:
      return whisperEngine.isModelLoaded
    }
  }

  func selectModel(_ model: SpeechModel) {
    modelLock.lock()
    selectedModel = model
    modelLock.unlock()
  }

  func preload(modelIdentifier: String) async throws {
    guard let model = SpeechModel(rawValue: modelIdentifier) else {
      throw MacSpeechEngineRouterError.invalidModelIdentifier(modelIdentifier)
    }
    selectModel(model)
    switch model.backendKind {
    case .granitePython:
      try await graniteEngine.loadModel(variant: model.rawValue)
    case .qwenMLX:
      try await qwenEngine.loadModel(variant: model.rawValue)
    case .whisperKit:
      try await whisperEngine.loadModel(variant: model.rawValue)
    }
  }

  func transcribe(samples: [Float]) async throws -> TranscriptionResult {
    let audioDuration = Double(samples.count) / Self.targetSampleRate
    guard audioDuration >= Self.minimumAudioDurationSeconds else {
      throw MacSpeechEngineRouterError.audioTooShort(duration: audioDuration)
    }

    let rawResult: TranscriptionResult
    switch currentModel.backendKind {
    case .granitePython:
      rawResult = try await graniteEngine.transcribe(audioBuffer: samples)
    case .qwenMLX:
      rawResult = try await qwenEngine.transcribe(audioBuffer: samples)
    case .whisperKit:
      rawResult = try await whisperEngine.transcribe(audioBuffer: samples)
    }

    let processedText = postProcessor.process(rawResult)
    return TranscriptionResult(
      text: processedText,
      segments: rawResult.segments,
      language: rawResult.language,
      processingTime: rawResult.processingTime,
      performanceMetrics: rawResult.performanceMetrics
    )
  }

  private var currentModel: SpeechModel {
    modelLock.lock()
    defer { modelLock.unlock() }
    return selectedModel
  }
}

final class MacOutputTextDeliverer: @unchecked Sendable, TextDelivering {
  private let outputManager: OutputManager
  private let targetPIDLock = NSLock()
  private var targetPID: pid_t?

  init(outputManager: OutputManager) {
    self.outputManager = outputManager
  }

  func setTargetPID(_ targetPID: pid_t?) {
    targetPIDLock.lock()
    self.targetPID = targetPID
    targetPIDLock.unlock()
  }

  func clearTargetPID() {
    setTargetPID(nil)
  }

  func deliver(text: String) async throws {
    let currentTargetPID = resolvedTargetPID
    await withCheckedContinuation { continuation in
      outputManager.deliver(text: text, targetPID: currentTargetPID) {
        continuation.resume()
      }
    }
  }

  private var resolvedTargetPID: pid_t? {
    targetPIDLock.lock()
    defer { targetPIDLock.unlock() }
    return targetPID
  }
}

// MARK: - Keyboard Shortcuts Extension

extension KeyboardShortcuts.Name {
  static let toggleTranscription = Self(
    "toggleTranscription", default: .init(.v, modifiers: .control))
}
