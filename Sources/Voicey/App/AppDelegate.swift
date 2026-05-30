import AppKit
import Carbon.HIToolbox
import KeyboardShortcuts
import SwiftUI
import VoiceyCore
import os

// AppDelegate is the legacy lifecycle coordinator. Keep size warnings disabled
// here until the existing recording/model/output responsibilities are split.
// swiftlint:disable type_body_length file_length
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

  private var loadingWindow: NSWindow?
  private var settingsWindow: NSWindow?

  private var audioCaptureManager: AudioCaptureManager?
  private var qwenEngine: QwenEngine?
  private var postProcessor: PostProcessor?
  private var outputManager: OutputManager?
  var incrementalTranscriptionCoordinator: IncrementalTranscriptionCoordinator?

  // The app that was frontmost when recording started (used for optional auto-paste)
  private var recordingTargetPID: pid_t?

  // The screen where recording was triggered (for overlay positioning)
  private var recordingTargetScreen: NSScreen?

  // ESC key monitors
  private var localEscKeyMonitor: Any?
  private var selectedModelObserver: Any?
  private var workspaceWakeObserver: Any?

  // Model upgrade lock - prevents recording during model swap
  private var isUpgradingModel = false
  private var handsFreeWaitTimeoutTask: Task<Void, Never>?
  /// When true, the next hands-free deliver appends a trailing space for the following utterance.
  private var handsFreeSeparateNextPasteWithSpace = false

  /// Held open with `flock(LOCK_NB)` so a second Voicey cannot register the same global shortcut.
  private var singleInstanceLockFileDescriptor: Int32 = -1

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
    let lockResult = VoiceySingleInstance.acquireLock(applyLockedFileDescriptor: { fd in
      self.singleInstanceLockFileDescriptor = fd
    })
    switch lockResult {
    case .acquired, .multipleInstancesAllowed:
      break
    case .alreadyRunning:
      return
    case .unavailable(let failure):
      VoiceySingleInstance.presentLockUnavailableAlert(
        failure: failure,
        lockPath: VoiceySingleInstance.productionLockOperations().lockFilePath()
      )
      NSApp.terminate(nil)
      return
    }

    // Keep the menubar app alive even when it has no open windows.
    ProcessInfo.processInfo.disableAutomaticTermination(Self.automaticTerminationReason)

    // Hide dock icon by default
    if !dependencies.settings.showDockIcon {
      NSApp.setActivationPolicy(.accessory)
    }

    // Initialize components
    setupComponents()

    SettingsManager.shared.migrateSelectedModelToUserFacingIfNeeded()

    #if VOICEY_DIRECT_DISTRIBUTION || VOICEY_MEDIA_REMOTE_PROBE
      // Defer MR registration: avoids re-entrancy during launch and keeps a bad MediaRemote call from
      // aborting startup before menubar/hotkey wiring runs.
      DispatchQueue.main.async {
        MediaRemoteNowPlayingNotifications.startIfNeeded()
      }
    #endif

    // Setup menubar
    statusBarController = StatusBarController(appState: appState, delegate: self)

    // Setup global hotkey
    setupHotkey()

    // Keep runtime state in sync when the user changes models from settings.
    setupSelectedModelObserver()

    // Setup ESC key monitor
    setupEscapeKeyMonitor()

    setupWorkspaceWakeObserver()

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
    debugPrint(
      "🔍 Has accessibility: \(hasAccessibility), auto-paste enabled: \(autoPasteEnabled)",
      category: "STARTUP")

    // Show onboarding if any required state is missing
    // This ensures users are guided through setup even if permissions were revoked
    let needsOnboarding = !hasModel || !hasMicrophone || needsAccessibility

    debugPrint("🔍 Needs onboarding: \(needsOnboarding)", category: "STARTUP")

    return needsOnboarding
  }

  func applicationWillTerminate(_ notification: Notification) {
    ProcessInfo.processInfo.enableAutomaticTermination(Self.automaticTerminationReason)
    cancelHandsFreeWaitTimeout()

    if let observer = workspaceWakeObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(observer)
      workspaceWakeObserver = nil
    }

    if let observer = selectedModelObserver {
      NotificationCenter.default.removeObserver(observer)
    }

    let shutdownSemaphore = DispatchSemaphore(value: 0)
    Task {
      await VoiceyRuntimeSupervisor.shared.shutdownGracefully()
      shutdownSemaphore.signal()
    }
    _ = shutdownSemaphore.wait(timeout: .now() + 6)

    // Remove monitors
    if let monitor = localEscKeyMonitor {
      NSEvent.removeMonitor(monitor)
    }
    dependencies.mediaPlayback.resumeAfterTranscription()

    // Clean up
    transcriptionOverlay = nil
  }

  // MARK: - Onboarding (now uses Settings window with Setup tab)

  private func showOnboarding() {
    // Open settings window - the Setup tab provides onboarding experience
    openSettings(targetTab: .setup)

    // Start model loading in background
    checkModelStatusAndPreload(showUI: false)
  }

  /// Whether the active Qwen engine (in-process or Rust infer worker) has a model loaded.
  private var isActiveEngineLoaded: Bool {
    let selectedModel = userFacingSelectedModel()
    if VoiceyRuntimeConfiguration.usesInferWorker(for: selectedModel) {
      return multiprocessInferReady
    }
    return qwenEngine?.isModelLoaded == true
  }

  private var multiprocessInferReady = false

  /// Returns the selected model after asserting it is user-facing (Qwen only).
  private func userFacingSelectedModel() -> SpeechModel {
    let model = SettingsManager.shared.selectedModel
    precondition(
      model.isUserFacing,
      "Benchmark-only model \(model.rawValue) must not reach the app transcription path"
    )
    return model
  }

  /// Best available Qwen fallback when the selected model cannot load.
  private func bestAvailableFallback(excluding failedBackend: SpeechBackendKind) -> SpeechModel? {
    let downloaded = ModelManager.shared.downloadedModels
    return SpeechModel.userFacingModels.first { downloaded.contains($0) }
  }

  @MainActor
  private func preloadQwen(selectedModel: SpeechModel) async -> Bool {
    guard VoiceyRuntimeConfiguration.usesInferWorker(for: selectedModel) else {
      await qwenEngine?.preloadModel()
      return qwenEngine?.isModelLoaded == true
    }

    qwenEngine?.unloadModel()
    do {
      try await VoiceyRuntimeSupervisor.shared.prewarmAllWorkers(model: selectedModel)
      multiprocessInferReady = true
      AppLogger.model.info(
        "Qwen infer worker prewarmed for \(selectedModel.rawValue, privacy: .public)"
      )
      return true
    } catch {
      multiprocessInferReady = false
      VoiceyRuntimeDiagnostics.recordInferWorkerError(error.localizedDescription)
      AppLogger.model.error("Infer worker prewarm failed: \(error.localizedDescription)")
      return false
    }
  }

  private func modelLoadFailureMessage(for model: SpeechModel) -> String {
    precondition(model.isUserFacing, "Benchmark-only model passed to app load failure handler")
    if VoiceyRuntimeConfiguration.usesInferWorker(for: model) {
      return VoiceyRuntimeDiagnostics.userFacingLoadFailureMessage()
    }
    return L10n.Runtime.genericModelLoadFailed
  }

  private func setupWorkspaceWakeObserver() {
    workspaceWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        await self?.handleSystemDidWake()
      }
    }
  }

  @MainActor
  private func handleSystemDidWake() async {
    let model = userFacingSelectedModel()
    guard VoiceyRuntimeConfiguration.usesInferWorker(for: model) else { return }

    let healthy = await VoiceyRuntimeSupervisor.shared.verifyInferWorkerHealth(model: model)
    guard !healthy else { return }

    multiprocessInferReady = false
    appState.modelStatus = .loading
    let preloadSucceeded = await preloadQwen(selectedModel: model)
    if preloadSucceeded && isActiveEngineLoaded {
      appState.modelStatus = .ready
    } else {
      appState.modelStatus = .failed(modelLoadFailureMessage(for: model))
    }
  }

  @MainActor
  private func preloadSelectedModel() async -> Bool {
    let selectedModel = userFacingSelectedModel()
    return await preloadQwen(selectedModel: selectedModel)
  }

  /// Preload selected model. If a backend fails to load, fall back to another downloaded backend automatically.
  @MainActor
  private func preloadSelectedModelWithFallback() async -> Bool {
    let selectedModel = SettingsManager.shared.selectedModel

    if await preloadSelectedModel() {
      return true
    }

    if selectedModel.isQwenModel,
      VoiceyRuntimeConfiguration.usesInferWorker(for: selectedModel),
      ModelManager.shared.isDownloaded(selectedModel) {
      return false
    }

    if let fallback = bestAvailableFallback(excluding: selectedModel.backendKind) {
      debugPrint(
        "⚠️ \(selectedModel.displayName) unavailable, falling back to \(fallback.displayName)",
        category: "MODEL"
      )
      SettingsManager.shared.selectedModel = fallback
      appState.currentModel = fallback
      return await preloadQwen(selectedModel: fallback)
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
    guard model.isUserFacing else {
      AppLogger.model.error("Ignoring benchmark-only model selection: \(model.rawValue)")
      return
    }

    appState.currentModel = model
    await unloadInactiveEngines()
    ModelManager.shared.loadDownloadedModels()

    guard ModelManager.shared.isDownloaded(model) else {
      appState.modelStatus = .notDownloaded
      return
    }

    appState.modelStatus = .loading
    appState.transcriptionState = .idle
    let preloadSucceeded = await preloadSelectedModel()
    if preloadSucceeded && isActiveEngineLoaded {
      appState.modelStatus = .ready
    } else {
      appState.modelStatus = .failed(modelLoadFailureMessage(for: model))
    }
  }

  @MainActor
  private func unloadInactiveEngines() async {
    let selectedModel = userFacingSelectedModel()
    if VoiceyRuntimeConfiguration.usesInferWorker(for: selectedModel) {
      qwenEngine?.unloadModel()
    } else {
      multiprocessInferReady = false
      await VoiceyRuntimeSupervisor.shared.shutdownInferWorkers()
    }
  }

  private func setupComponents() {
    audioCaptureManager = AudioCaptureManager()
    audioCaptureManager?.delegate = self

    qwenEngine = QwenEngine()
    qwenEngine?.onLoadingStateChanged = { [weak self] isLoading in
      if isLoading {
        self?.appState.transcriptionState = .loadingModel
      } else if self?.appState.transcriptionState == .loadingModel {
        self?.appState.transcriptionState = .idle
      }
    }
    qwenEngine?.onPerformanceIssue = { [weak self] metrics in
      self?.handlePerformanceIssue(metrics)
    }

    postProcessor = PostProcessor()
    outputManager = OutputManager()
    incrementalTranscriptionCoordinator = IncrementalTranscriptionCoordinator(
      transcribe: { [weak self] audioBuffer in
        guard let self else {
          throw TranscriptionError.audioCaptureFailed
        }
        return try await self.transcribeWithSelectedEngine(audioBuffer: audioBuffer)
      },
      onUpdate: { [weak self] snapshot in
        guard let self else { return }
        await MainActor.run {
          self.appState.partialTranscription = snapshot.partialText
          self.appState.isCatchingUpTranscription = snapshot.isCatchingUp
        }
      }
    )

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
      Task { @MainActor in
        AppLogger.general.info("Received transcription trigger from keyboard shortcut")
        self?.toggleTranscription()
      }
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
            let model = SettingsManager.shared.selectedModel
            appState.modelStatus = .failed(self.modelLoadFailureMessage(for: model))
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
      // No model and no download - route users to settings instead of a separate modal.
      appState.modelStatus = .notDownloaded
      debugPrint("📥 No model downloaded, opening settings on Model tab", category: "MODEL")
      if showUI {
        Task { @MainActor in
          try? await Task.sleep(nanoseconds: 500_000_000)  // 0.5 seconds
          self.openSettings(targetTab: .model)
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
    debugPrint(
      "🔄 Upgrading from \(previousModel.displayName) → \(model.displayName)...", category: "MODEL")

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

        guard model.isUserFacing else {
          throw QwenError.invalidModel
        }

        if VoiceyRuntimeConfiguration.usesInferWorker(for: model) {
          await MainActor.run {
            SettingsManager.shared.selectedModel = model
            appState.currentModel = model
          }
          let preloaded = await preloadQwen(selectedModel: model)
          guard preloaded else {
            throw QwenError.modelNotReady
          }
        } else {
          guard let qwenEngine else {
            throw QwenError.modelNotReady
          }
          try await qwenEngine.loadModel(variant: model.rawValue)
          guard qwenEngine.isModelLoaded else {
            throw QwenError.modelNotReady
          }
        }

        let loadTime = CFAbsoluteTimeGetCurrent() - startTime

        await MainActor.run {
          SettingsManager.shared.selectedModel = model
          appState.currentModel = model
          ModelManager.shared.pendingUpgradeModel = nil
          appState.modelStatus = .ready
          qwenEngine?.resetPerformanceTracking()
          debugPrint(
            "✅ Upgraded to \(model.displayName) in \(String(format: "%.1f", loadTime))s!",
            category: "MODEL")
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
      Text(L10n.LoadingWindow.title)
        .font(.headline)
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
          let model = SettingsManager.shared.selectedModel
          appState.modelStatus = .failed(modelLoadFailureMessage(for: model))
        }
      }
    }
  }

  // MARK: - Transcription Control

  func toggleTranscription() {
    if appState.handsFreeSessionActive {
      endHandsFreeSession()
      return
    }
    if appState.isRecording {
      stopRecording()
    } else {
      startRecording()
    }
  }

  private func startRecording() {
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
      AppLogger.general.warning(
        "startRecording: No models downloaded, opening settings on Model tab")
      openSettings(targetTab: .model)
      return
    }

    // If selected model isn't downloaded, switch to the best available Qwen model.
    if !ModelManager.shared.isDownloaded(selectedModel),
      let fallbackModel = SpeechModel.userFacingModels.first(where: {
        downloadedModels.contains($0)
      }) {
      AppLogger.general.info(
        "startRecording: Selected model not available, switching to \(fallbackModel.rawValue)")
      SettingsManager.shared.selectedModel = fallbackModel
      appState.currentModel = fallbackModel
      selectedModel = fallbackModel
    }

    // If the newly selected backend is not loaded yet, load it before recording.
    if !isActiveEngineLoaded {
      debugPrint("⏳ Selected model is not loaded yet - loading now...", category: "RECORD")
      appState.modelStatus = .loading
      appState.transcriptionState = .loadingModel
      showOverlay()

      Task {
        await self.unloadInactiveEngines()
        let preloadSucceeded = await self.preloadSelectedModel()

        await MainActor.run {
          if preloadSucceeded && self.isActiveEngineLoaded {
            self.appState.modelStatus = .ready
            self.beginRecordingAfterModelReady()
          } else {
            self.hideOverlay()
            let model = SettingsManager.shared.selectedModel
            self.appState.modelStatus = .failed(self.modelLoadFailureMessage(for: model))
            self.appState.transcriptionState = .error(
              message: self.modelLoadFailureMessage(for: model))
            self.dependencies.notifications.showTranscriptionError(
              self.modelLoadFailureMessage(for: model))
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
            let model = SettingsManager.shared.selectedModel
            let message = self.modelLoadFailureMessage(for: model)
            self.appState.transcriptionState = .error(message: message)
            self.dependencies.notifications.showTranscriptionError(message)
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

    startScreenContextCaptureIfNeeded()

    if dependencies.settings.pauseMediaDuringTranscription {
      dependencies.mediaPlayback.pauseForTranscription()
    }
    appState.clearRecordingWaveformDisplay()
    incrementalTranscriptionCoordinator?.reset()
    appState.partialTranscription = ""
    appState.isCatchingUpTranscription = false
    let recordingMode = dependencies.settings.recordingMode
    if recordingMode == .handsFree {
      appState.handsFreeSessionActive = true
      handsFreeSeparateNextPasteWithSpace = false
      appState.resetHandsFreeBackgroundTranscriptionJobs()
      appState.transcriptionState = .waitingForSpeech(startTime: Date())
      scheduleHandsFreeWaitTimeout()
      AppLogger.audio.info("Hands-Free: Armed and waiting for speech")
    } else {
      appState.transcriptionState = .recording(startTime: Date())
    }

    // Show overlay on the screen where the user was last interacting
    showOverlay()

    // Start audio capture
    audioCaptureManager?.startCapture(mode: recordingMode)

    // Update menubar
    statusBarController?.updateIcon(recording: true)
  }

  /// Determine which screen contains the key window of the given application
  private func screenForApplication(_ app: NSRunningApplication?) -> NSScreen? {
    guard let app = app else { return nil }

    // Get the window list for all on-screen windows
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard
      let windowInfoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
    else {
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
      let height = boundsDict["Height"]
    else {
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

  private func startScreenContextCaptureIfNeeded() {
    ScreenContextStore.shared.clear()

    guard dependencies.settings.transcriptionScreenContextEnabled else { return }
    guard dependencies.permissions.checkAccessibilityPermission() else {
      AppLogger.transcription.warning(
        "Screen context enabled but Accessibility permission is not granted")
      return
    }
    guard let targetPID = recordingTargetPID else { return }

    Task.detached(priority: .utility) {
      let windowImage = ScreenContextOCR.grabFrontWindowImageSync(targetPID: targetPID)
      let captured = ScreenContextCollector.captureWithExposure(targetPID: targetPID)
      var snapshot = captured.snapshot

      let ocrEnabled = SettingsManager.shared.transcriptionScreenContextOCREnabled
      let screenCaptureGranted = PermissionsManager.shared.checkScreenCapturePermission()
      if captured.exposure.shouldConsiderOCRFallback, ocrEnabled, screenCaptureGranted,
        let windowImage {
        if let ocrSnapshot = await ScreenContextOCR.recognizeText(in: windowImage) {
          snapshot = ScreenContextSnapshotMerger.merging(snapshot, supplemental: ocrSnapshot)
        }
      } else if captured.exposure.shouldConsiderOCRFallback, ocrEnabled, !screenCaptureGranted {
        AppLogger.transcription.warning(
          "ScreenContext OCR enabled but Screen Recording permission is not granted")
      }

      ScreenContextStore.shared.set(snapshot, exposure: captured.exposure)
    }
  }

  func enforceRecordingDurationLimitIfNeeded() {
    guard case .recording(let startTime) = appState.transcriptionState else { return }
    let elapsed = Date().timeIntervalSince(startTime)
    guard elapsed >= RecordingDurationLimits.maxSeconds else { return }
    AppLogger.audio.info(
      "Recording reached maximum duration (\(Int(RecordingDurationLimits.maxSeconds))s); stopping for transcription"
    )
    if appState.handsFreeSessionActive {
      finishHandsFreeUtteranceAndContinueListening()
    } else {
      stopRecording()
    }
  }

  func finishHandsFreeUtteranceAndContinueListening() {
    guard appState.handsFreeSessionActive, appState.isRecording else { return }

    AppLogger.audio.info("Hands-Free: Finalizing utterance; capture continues")

    guard
      let audioBuffer = audioCaptureManager?.finalizeHandsFreeUtterance(
        applyTrailingTrimHeuristic: true)
    else {
      AppLogger.audio.error("Hands-Free: Failed to finalize utterance buffer")
      audioCaptureManager?.recoverHandsFreeDetectorForNextUtterance()
      appState.transcriptionState = .waitingForSpeech(startTime: Date())
      return
    }

    appState.clearRecordingWaveformDisplay()
    appState.transcriptionState = .waitingForSpeech(startTime: Date())

    let durationSec = Double(audioBuffer.count) / 16000.0
    AppLogger.audio.info(
      "Hands-Free utterance: \(audioBuffer.count) samples (~\(String(format: "%.1f", durationSec))s)"
    )

    guard durationSec >= 0.5 else {
      AppLogger.audio.warning("Hands-Free utterance too short; resuming listen")
      return
    }

    Task {
      await processTranscription(
        capturedAudio: .inMemory(audioBuffer),
        continueHandsFreeSession: true,
        appendTrailingSpaceForNextUtterance: true
      )
    }
  }

  func endHandsFreeSession() {
    AppLogger.general.info("Ending hands-free session")
    cancelHandsFreeWaitTimeout()

    appState.handsFreeSessionActive = false
    handsFreeSeparateNextPasteWithSpace = false

    var finalUtterance: [Float]?
    if appState.isRecording {
      finalUtterance = audioCaptureManager?.finalizeHandsFreeUtteranceForSessionEnd(
        applyTrailingTrimHeuristic: true)
    }

    if let discardedCapture = audioCaptureManager?.stopCapture() {
      discardedCapture.removeSharedBufferIfNeeded()
    }
    statusBarController?.updateIcon(recording: false)

    if dependencies.settings.pauseMediaDuringTranscription {
      dependencies.mediaPlayback.resumeAfterTranscription()
    }

    guard let audioBuffer = finalUtterance else {
      appState.resetHandsFreeBackgroundTranscriptionJobs()
      appState.transcriptionState = .idle
      appState.clearRecordingWaveformDisplay()
      hideOverlay()
      tryPerformPendingUpgrade()
      return
    }

    let durationSec = Double(audioBuffer.count) / 16000.0
    guard durationSec >= 0.5 else {
      AppLogger.audio.warning(
        "Hands-Free session end: utterance too short (\(String(format: "%.2f", durationSec))s)"
      )
      appState.resetHandsFreeBackgroundTranscriptionJobs()
      appState.transcriptionState = .idle
      appState.clearRecordingWaveformDisplay()
      hideOverlay()
      tryPerformPendingUpgrade()
      return
    }

    appState.resetHandsFreeBackgroundTranscriptionJobs()
    let selectedModel = userFacingSelectedModel()
    let capturedAudio = CapturedAudio.inMemory(audioBuffer)
    configureProcessingWaveformDisplay(
      capturedAudio: capturedAudio,
      durationSec: durationSec,
      model: selectedModel
    )
    appState.transcriptionState = .processing
    showOverlay()

    Task {
      await processTranscription(
        capturedAudio: capturedAudio,
        continueHandsFreeSession: false,
        appendTrailingSpaceForNextUtterance: false,
        pasteToCurrentFrontmost: true
      )
    }
  }

  func stopRecording() {
    guard appState.isRecording else { return }
    cancelHandsFreeWaitTimeout()

    debugPrint("⏹️ Stopping recording...", category: "RECORD")
    AppLogger.audio.info("Stopping recording...")

    // Always reset the menubar icon out of recording mode, including early-return paths.
    defer {
      statusBarController?.updateIcon(recording: false)
    }

    let selectedModel = userFacingSelectedModel()
    let applyTrailingTrimHeuristic = !selectedModel.isGraniteModel

    // Stop audio capture. The coordinator already received the streamed samples;
    // the returned buffer is used for duration/minimum-audio checks only.
    guard
      let capturedAudio = audioCaptureManager?.stopCapture(
        applyTrailingTrimHeuristic: false)
    else {
      debugPrint("❌ No audio buffer!", category: "ERROR")
      AppLogger.audio.error("No audio buffer!")
      hideOverlay()
      appState.transcriptionState = .error(message: "No audio captured")
      dependencies.mediaPlayback.resumeAfterTranscription()
      return
    }

    let durationSec = capturedAudio.durationSeconds
    debugPrint(
      "📊 Got \(capturedAudio.sampleCount) samples (~\(String(format: "%.1f", durationSec))s of audio)",
      category: "AUDIO")
    AppLogger.audio.info(
      "Got audio buffer with \(capturedAudio.sampleCount) samples (~\(String(format: "%.1f", durationSec))s)"
    )

    // Check minimum duration (0.5 seconds)
    if durationSec < 0.5 {
      capturedAudio.removeSharedBufferIfNeeded()
      debugPrint(
        "⚠️ Audio too short (\(String(format: "%.2f", durationSec))s), skipping", category: "AUDIO")
      AppLogger.audio.warning(
        "Audio too short (\(String(format: "%.2f", durationSec))s), skipping transcription")
      hideOverlay()
      appState.clearRecordingWaveformDisplay()
      appState.transcriptionState = .idle
      dependencies.mediaPlayback.resumeAfterTranscription()
      // Check for pending model upgrade now that we're idle
      tryPerformPendingUpgrade()
      return
    }

    // Mic is off; resume system media while the model runs (pause only covered recording).
    if dependencies.settings.pauseMediaDuringTranscription {
      dependencies.mediaPlayback.resumeAfterTranscription()
    }

    configureProcessingWaveformDisplay(
      capturedAudio: capturedAudio,
      durationSec: durationSec,
      model: selectedModel
    )
    appState.transcriptionState = .processing

    guard let incrementalTranscriptionCoordinator else {
      hideOverlay()
      appState.transcriptionState = .error(message: "Transcription pipeline unavailable")
      dependencies.notifications.showTranscriptionError("Transcription pipeline unavailable")
      return
    }

    // Finish any queued pause chunks and transcribe the final tail.
    Task {
      defer { capturedAudio.removeSharedBufferIfNeeded() }
      await processIncrementalTranscription(
        coordinator: incrementalTranscriptionCoordinator,
        applyTrailingTrimHeuristic: applyTrailingTrimHeuristic
      )
    }
  }

  func cancelTranscription() {
    if appState.handsFreeSessionActive {
      endHandsFreeSession()
      return
    }

    AppLogger.general.info("Cancelling transcription...")
    cancelHandsFreeWaitTimeout()
    appState.handsFreeSessionActive = false

    appState.transcriptionState = .idle
    appState.clearRecordingWaveformDisplay()
    appState.partialTranscription = ""
    appState.isCatchingUpTranscription = false
    incrementalTranscriptionCoordinator?.cancel()

    // Stop and discard audio (release shared PCM file if capture used voicey-capture).
    if let capturedAudio = audioCaptureManager?.stopCapture(applyTrailingTrimHeuristic: false) {
      capturedAudio.removeSharedBufferIfNeeded()
    }

    // Hide overlay
    hideOverlay()

    // Update menubar
    statusBarController?.updateIcon(recording: false)

    dependencies.mediaPlayback.resumeAfterTranscription()

    // Check for pending model upgrade now that we're idle
    tryPerformPendingUpgrade()
  }

  private func processIncrementalTranscription(
    coordinator: IncrementalTranscriptionCoordinator,
    applyTrailingTrimHeuristic: Bool
  ) async {
    do {
      debugPrint("🔄 Finishing incremental transcription...", category: "TRANSCRIBE")
      let result = try await coordinator.flushAndFinish(
        applyTrailingTrimHeuristic: applyTrailingTrimHeuristic)
      await handleTranscriptionResult(result)
    } catch {
      await handleTranscriptionError(error)
    }
  }

  private func transcribeWithSelectedEngine(audioBuffer: [Float]) async throws -> TranscriptionResult {
    let selectedModel = userFacingSelectedModel()
    let decoderContext = TranscriptionSteeringContext.make()
    if VoiceyRuntimeConfiguration.usesInferWorker(for: selectedModel) {
      return try await VoiceyRuntimeSupervisor.shared.transcribe(
        samples: audioBuffer,
        model: selectedModel,
        warmupAlreadyDone: multiprocessInferReady,
        decoderContext: decoderContext
      )
    }
    guard
      let qwenResult = try await qwenEngine?.transcribe(
        audioBuffer: audioBuffer,
        decoderContext: decoderContext
      )
    else {
      throw TranscriptionError.transcriptionFailed("No result from Qwen engine")
    }
    return qwenResult
  }

  private func handleTranscriptionResult(_ result: TranscriptionResult) async {
    debugPrint("📝 Raw result: \"\(result.text)\"", category: "TRANSCRIBE")
    AppLogger.transcription.info("processTranscription: Got raw result: \"\(result.text)\"")

    // Post-process text
    let processedText = await postProcessor?.processAsync(result) ?? result.text
    debugPrint("✨ Processed text: \"\(processedText)\"", category: "TRANSCRIBE")
    AppLogger.transcription.info(
      "processTranscription: Processed text: \"\(processedText)\" (length: \(processedText.count))"
    )
    let hasDeliverableText =
      processedText.rangeOfCharacter(from: .whitespacesAndNewlines.inverted) != nil

    let selectedModel = SettingsManager.shared.selectedModel
    if selectedModel.isQwenModel {
      await MainActor.run {
        appState.recordQwenTranscriptionRTF(result.performanceMetrics.realTimeFactor)
      }
    }

    // Output text
    await MainActor.run {
      appState.transcriptionState = .completed(text: processedText)
      appState.lastTranscription = processedText
      appState.partialTranscription = ""
      appState.isCatchingUpTranscription = false

      // Check if we have any text to deliver
      if !hasDeliverableText {
        debugPrint("⚠️ No text to deliver (empty after processing)", category: "OUTPUT")
        AppLogger.transcription.warning(
          "processTranscription: No text to deliver (empty/whitespace after processing)")
        self.hideOverlay()
        self.appState.transcriptionState = .idle
        self.tryPerformPendingUpgrade()
        return
      }

      debugPrint("📋 Copying to clipboard: \"\(processedText)\"", category: "OUTPUT")

      outputManager?.deliver(text: processedText, targetPID: self.recordingTargetPID) { [weak self] in
        debugPrint("✅ Text copied to clipboard", category: "OUTPUT")
        self?.hideOverlay()
        self?.appState.transcriptionState = .idle
        self?.tryPerformPendingUpgrade()
      }

      self.recordingTargetPID = nil
      self.recordingTargetScreen = nil
    }
  }

  private func handleTranscriptionError(_ error: Error) async {
    debugPrint("❌ Transcription error: \(error)", category: "ERROR")
    AppLogger.transcription.error("Transcription error: \(error)")
    await MainActor.run { [weak self] in
      self?.hideOverlay()
      self?.appState.partialTranscription = ""
      self?.appState.isCatchingUpTranscription = false
      self?.appState.transcriptionState = .error(message: error.localizedDescription)
      self?.dependencies.notifications.showTranscriptionError(error.localizedDescription)
      self?.tryPerformPendingUpgrade()
    }
  }

  func cancelHandsFreeWaitTimeout() {
    handsFreeWaitTimeoutTask?.cancel()
    handsFreeWaitTimeoutTask = nil
  }

  private func scheduleHandsFreeWaitTimeout() {
    cancelHandsFreeWaitTimeout()

    let timeoutDuration = audioCaptureManager?.handsFreeWaitTimeoutDuration ?? 8.0
    handsFreeWaitTimeoutTask = Task { [weak self] in
      guard timeoutDuration > 0 else { return }
      let timeoutNanoseconds = UInt64(timeoutDuration * 1_000_000_000)
      try? await Task.sleep(nanoseconds: timeoutNanoseconds)

      await MainActor.run {
        guard let self, self.appState.isWaitingForSpeech else { return }
        AppLogger.audio.info("Hands-Free: No speech detected before timeout; cancelling")
        self.cancelTranscription()
      }
    }
  }

  @MainActor
  private func registerHandsFreeBackgroundTranscriptionJobIfNeeded(
    model: SpeechModel,
    capturedAudio: CapturedAudio,
    durationSec: Double
  ) -> UUID? {
    guard model.isQwenModel else { return nil }
    let envelope: [Float]
    switch capturedAudio {
    case .inMemory(let samples):
      envelope = AudioWaveformEnvelope.normalizedBars(from: samples)
    case .sharedBuffer:
      envelope = Array(repeating: 0.08, count: AudioWaveformEnvelope.displayBarCount)
    }
    let estimatedRTF = estimatedTranscriptionRTF(for: model)
    return appState.addHandsFreeBackgroundTranscriptionJob(
      envelope: envelope,
      audioDuration: durationSec,
      estimatedRTF: estimatedRTF
    )
  }

  @MainActor
  private func transcriptionPasteTargetPID(pasteToCurrentFrontmost: Bool) -> pid_t? {
    if pasteToCurrentFrontmost || appState.handsFreeSessionActive {
      return nil
    }
    return recordingTargetPID
  }

  /// Restores hands-free "waiting for speech" only when capture is not mid-utterance.
  private func restoreHandsFreeWaitingForSpeechIfNotRecording() {
    guard appState.handsFreeSessionActive, !appState.isRecording else { return }
    appState.transcriptionState = .waitingForSpeech(startTime: Date())
  }

  private func processTranscription(
    capturedAudio: CapturedAudio,
    continueHandsFreeSession: Bool = false,
    appendTrailingSpaceForNextUtterance: Bool = false,
    pasteToCurrentFrontmost: Bool = false
  ) async {
    let durationSec = capturedAudio.durationSeconds
    let selectedModel = userFacingSelectedModel()
    var backgroundJobID: UUID?
    if continueHandsFreeSession {
      await MainActor.run {
        backgroundJobID = self.registerHandsFreeBackgroundTranscriptionJobIfNeeded(
          model: selectedModel,
          capturedAudio: capturedAudio,
          durationSec: durationSec
        )
        self.transcriptionOverlay?.syncLayout(to: self.appState)
      }
    }
    defer {
      if let backgroundJobID {
        let jobID = backgroundJobID
        Task { @MainActor in
          self.appState.removeHandsFreeBackgroundTranscriptionJob(id: jobID)
          self.transcriptionOverlay?.syncLayout(to: self.appState)
        }
      }
    }

    do {
      debugPrint("🔄 Starting transcription...", category: "TRANSCRIBE")
      AppLogger.transcription.info(
        "processTranscription: Starting with \(capturedAudio.sampleCount) samples")

      let decoderContext = TranscriptionSteeringContext.make()
      let result: TranscriptionResult
      if VoiceyRuntimeConfiguration.usesInferWorker(for: selectedModel) {
        result = try await VoiceyRuntimeSupervisor.shared.transcribe(
          capturedAudio: capturedAudio,
          model: selectedModel,
          warmupAlreadyDone: multiprocessInferReady,
          decoderContext: decoderContext
        )
      } else {
        let audioBuffer = try capturedAudio.inMemorySamples()
        defer { capturedAudio.removeSharedBufferIfNeeded() }
        guard
          let qwenResult = try await qwenEngine?.transcribe(
            audioBuffer: audioBuffer,
            decoderContext: decoderContext
          )
        else {
          throw TranscriptionError.transcriptionFailed("No result from Qwen engine")
        }
        result = qwenResult
      }

      debugPrint("📝 Raw result: \"\(result.text)\"", category: "TRANSCRIBE")
      AppLogger.transcription.info("processTranscription: Got raw result: \"\(result.text)\"")

      let processedText = await postProcessor?.processAsync(result) ?? result.text
      debugPrint("✨ Processed text: \"\(processedText)\"", category: "TRANSCRIBE")
      AppLogger.transcription.info(
        "processTranscription: Processed text: \"\(processedText)\" (length: \(processedText.count))"
      )
      let hasDeliverableText =
        processedText.rangeOfCharacter(from: .whitespacesAndNewlines.inverted) != nil

      if selectedModel.isQwenModel {
        await MainActor.run {
          appState.recordQwenTranscriptionRTF(result.performanceMetrics.realTimeFactor)
        }
      }

      await MainActor.run {
        appState.lastTranscription = processedText

        if !hasDeliverableText {
          debugPrint("⚠️ No text to deliver (empty after processing)", category: "OUTPUT")
          AppLogger.transcription.warning(
            "processTranscription: No text to deliver (empty/whitespace after processing)")
          if continueHandsFreeSession, self.appState.handsFreeSessionActive {
            self.restoreHandsFreeWaitingForSpeechIfNotRecording()
            self.tryPerformPendingUpgrade()
            return
          }
          self.hideOverlay()
          self.appState.transcriptionState = .idle
          self.tryPerformPendingUpgrade()
          return
        }

        debugPrint("📋 Copying to clipboard: \"\(processedText)\"", category: "OUTPUT")

        var deliverText = processedText
        if appendTrailingSpaceForNextUtterance || self.handsFreeSeparateNextPasteWithSpace {
          deliverText = TextCleanup.appendingInterUtteranceSpacingIfNeeded(deliverText)
        }
        if appendTrailingSpaceForNextUtterance {
          self.handsFreeSeparateNextPasteWithSpace = true
        }

        let pasteTargetPID = self.transcriptionPasteTargetPID(
          pasteToCurrentFrontmost: pasteToCurrentFrontmost
        )

        outputManager?.deliver(
          text: deliverText,
          targetPID: pasteTargetPID,
          completion: { [weak self] in
            debugPrint("✅ Text copied to clipboard", category: "OUTPUT")
            guard let self else { return }
            if continueHandsFreeSession, self.appState.handsFreeSessionActive {
              self.restoreHandsFreeWaitingForSpeechIfNotRecording()
              self.tryPerformPendingUpgrade()
              return
            }
            self.hideOverlay()
            self.appState.transcriptionState = .idle
            self.tryPerformPendingUpgrade()
          }
        )

        if continueHandsFreeSession {
          self.restoreHandsFreeWaitingForSpeechIfNotRecording()
        } else {
          self.appState.transcriptionState = .completed(text: processedText)
        }

        if !continueHandsFreeSession {
          self.recordingTargetPID = nil
          self.recordingTargetScreen = nil
        }
      }
    } catch {
      debugPrint("❌ Transcription error: \(error)", category: "ERROR")
      AppLogger.transcription.error("Transcription error: \(error)")
      await MainActor.run { [weak self] in
        guard let self else { return }
        if continueHandsFreeSession, self.appState.handsFreeSessionActive {
          self.restoreHandsFreeWaitingForSpeechIfNotRecording()
          self.dependencies.notifications.showTranscriptionError(error.localizedDescription)
          self.tryPerformPendingUpgrade()
          return
        }
        self.hideOverlay()
        self.appState.transcriptionState = .error(message: error.localizedDescription)
        self.dependencies.notifications.showTranscriptionError(error.localizedDescription)
        self.tryPerformPendingUpgrade()
      }
    }
  }

  // MARK: - Overlay

  private func configureProcessingWaveformDisplay(
    capturedAudio: CapturedAudio,
    durationSec: TimeInterval,
    model: SpeechModel
  ) {
    guard model.isQwenModel else { return }
    let envelope: [Float]
    switch capturedAudio {
    case .inMemory(let samples):
      envelope = AudioWaveformEnvelope.normalizedBars(from: samples)
    case .sharedBuffer:
      envelope = Array(repeating: 0.08, count: AudioWaveformEnvelope.displayBarCount)
    }
    let estimatedRTF = estimatedTranscriptionRTF(for: model)
    appState.prepareTranscriptionProgressDisplay(
      envelope: envelope,
      audioDuration: durationSec,
      estimatedRTF: estimatedRTF
    )
  }

  private func estimatedTranscriptionRTF(for model: SpeechModel) -> Double {
    if let average = appState.averageQwenTranscriptionRTF, average > 0 {
      return average
    }
    if let inProcessAverage = qwenEngine?.averageRTF, inProcessAverage > 0 {
      return inProcessAverage
    }
    return AppState.defaultEstimatedRTF(for: model)
  }

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
      transcriptionOverlay?.syncLayout(to: appState)
    }
  }

  private func hideOverlay() {
    Task { @MainActor [weak self] in
      self?.transcriptionOverlay?.hide()
      self?.appState.clearRecordingWaveformDisplay()
    }
  }

  // MARK: - Public Actions

  func openSettings(targetTab: SettingsView.Tab? = nil) {
    // Reuse an existing settings window when possible, even if it was hidden.
    if let existingWindow = settingsWindow {
      existingWindow.makeKeyAndOrderFront(nil)
      if let targetTab {
        NotificationCenter.default.post(
          name: .voiceyOpenSettingsTab,
          object: targetTab.rawValue
        )
      }
      NSApp.activate(ignoringOtherApps: true)
      return
    }

    // Create settings window manually since SwiftUI Settings scene doesn't work well with accessory apps
    let settingsView = SettingsView(initialTab: targetTab)
      .environmentObject(appState)

    let hostingController = NSHostingController(rootView: settingsView)

    let window = NSWindow(contentViewController: hostingController)
    window.title = "Voicey Settings"
    window.styleMask = [.titled, .closable]
    window.titlebarAppearsTransparent = true
    window.toolbarStyle = .unified
    window.setContentSize(SettingsView.windowSize)
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

  func showAbout() {
    NSApp.activate(ignoringOtherApps: true)
    NSApp.orderFrontStandardAboutPanel(nil)
  }

  func quit() {
    NSApp.terminate(nil)
  }
}
// swiftlint:enable type_body_length
