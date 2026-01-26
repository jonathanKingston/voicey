import AppKit
import AVFoundation
import KeyboardShortcuts
import SwiftUI

/// Main settings view with tabbed interface
struct SettingsView: View {
  enum Tab: Hashable {
    case setup, general, hotkey, audio, model, voiceCommands, advanced
  }

  @State private var selectedTab: Tab = .setup
  @ObservedObject private var modelManager = ModelManager.shared
  @State private var microphoneGranted = false

  /// Whether setup is complete (model downloaded + mic permission)
  private var isSetupComplete: Bool {
    microphoneGranted && modelManager.hasDownloadedModel
  }

  var body: some View {
    TabView(selection: $selectedTab) {
      SetupSettingsView()
        .tabItem {
          Label(L10n.Settings.setup, systemImage: "checkmark.circle")
        }
        .tag(Tab.setup)

      GeneralSettingsView()
        .tabItem {
          Label(L10n.Settings.general, systemImage: "gear")
        }
        .tag(Tab.general)

      HotkeySettingsView()
        .tabItem {
          Label(L10n.Settings.hotkey, systemImage: "keyboard")
        }
        .tag(Tab.hotkey)

      AudioSettingsView()
        .tabItem {
          Label(L10n.Settings.audio, systemImage: "mic")
        }
        .tag(Tab.audio)

      ModelSettingsView()
        .tabItem {
          Label(L10n.Settings.model, systemImage: "cpu")
        }
        .tag(Tab.model)

      VoiceCommandsSettingsView()
        .tabItem {
          Label(L10n.Settings.voiceCommands, systemImage: "text.bubble")
        }
        .tag(Tab.voiceCommands)

      AdvancedSettingsView()
        .tabItem {
          Label(L10n.Settings.advanced, systemImage: "wrench.and.screwdriver")
        }
        .tag(Tab.advanced)
    }
    .frame(width: 500, height: 550)
    .task {
      microphoneGranted = await PermissionsManager.shared.checkMicrophonePermission()
      if isSetupComplete {
        selectedTab = .general
      }
    }
  }
}

// MARK: - Setup Settings (Onboarding-style status view)

struct SetupSettingsView: View {
  @State private var microphoneGranted = false
  @State private var launchAtLoginEnabled = false

  @ObservedObject private var modelManager = ModelManager.shared

  /// The fast model to download first for quick startup (language-aware)
  private var fastModel: WhisperModel { ModelManager.fastModel }

  /// The high-quality model to download in background
  private let qualityModel = ModelManager.qualityModel

  /// Whether all required setup is complete
  private var isSetupComplete: Bool {
    microphoneGranted && modelManager.hasDownloadedModel
  }

  /// Whether fast model is currently downloading
  private var isFastModelDownloading: Bool {
    modelManager.isDownloading[fastModel] == true
  }

  /// Whether quality model is currently downloading
  private var isQualityModelDownloading: Bool {
    modelManager.isDownloading[qualityModel] == true
  }

  /// Whether fast model is ready
  private var isFastModelReady: Bool {
    modelManager.hasDownloadedModel || modelManager.isDownloaded(fastModel)
  }

  /// Whether quality model is ready
  private var isQualityModelReady: Bool {
    modelManager.isDownloaded(qualityModel)
  }

  /// Download progress for fast model (0-1)
  private var fastDownloadProgress: Double {
    modelManager.downloadProgress[fastModel] ?? 0
  }

  /// Download progress for quality model (0-1)
  private var qualityDownloadProgress: Double {
    modelManager.downloadProgress[qualityModel] ?? 0
  }

  var body: some View {
    VStack(spacing: 0) {
      // Header
      VStack(spacing: 8) {
        Image(nsImage: NSApp.applicationIconImage)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(width: 64, height: 64)

        Text(L10n.App.name)
          .font(.title2)
          .fontWeight(.bold)

        Text(L10n.App.tagline)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      .padding(.top, 20)
      .padding(.bottom, 16)

      Divider()
        .padding(.horizontal, 20)

      // Setup steps
      VStack(spacing: 10) {
        // Step 1: Model Download
        SetupStepRow(
          stepNumber: 1,
          icon: "cpu",
          title: L10n.Setup.downloadModel,
          description: L10n.Setup.downloadModelDesc(fastModel.displayName),
          isComplete: isFastModelReady,
          isInProgress: isFastModelDownloading,
          progress: fastDownloadProgress,
          buttonTitle: isFastModelReady
            ? L10n.Setup.ready : (isFastModelDownloading ? L10n.Setup.downloading : L10n.Setup.download),
          action: startFastModelDownload
        )

        // Step 1b: Quality Model Download (optional upgrade)
        SetupStepRow(
          stepNumber: 0,
          icon: "sparkles",
          title: L10n.Setup.downloadQualityModel,
          description: L10n.Setup.downloadQualityModelDesc(qualityModel.displayName),
          isComplete: isQualityModelReady,
          isInProgress: isQualityModelDownloading,
          progress: qualityDownloadProgress,
          isOptional: true,
          buttonTitle: isQualityModelReady
            ? L10n.Setup.ready
            : (isQualityModelDownloading
              ? L10n.Setup.downloading : (isFastModelReady ? L10n.Setup.download : L10n.Setup.afterFastModel)),
          action: startQualityModelDownload
        )
        .disabled(!isFastModelReady && !isQualityModelDownloading)
        .opacity(isFastModelReady || isQualityModelDownloading || isQualityModelReady ? 1.0 : 0.6)

        // Step 2: Microphone
        SetupStepRow(
          stepNumber: 2,
          icon: "mic.fill",
          title: L10n.Setup.microphoneAccess,
          description: L10n.Setup.microphoneAccessDesc,
          isComplete: microphoneGranted,
          buttonTitle: microphoneGranted ? L10n.Setup.granted : L10n.Setup.allow,
          action: requestMicrophonePermission
        )

        // Step 3: Launch at Login (optional)
        SetupStepRow(
          stepNumber: 3,
          icon: "arrow.clockwise",
          title: L10n.Setup.launchAtLogin,
          description: L10n.Setup.launchAtLoginDesc,
          isComplete: launchAtLoginEnabled,
          isOptional: true,
          buttonTitle: launchAtLoginEnabled ? L10n.Setup.enabled : L10n.Setup.enable,
          action: enableLaunchAtLogin
        )
      }
      .padding(.top, 20)

      Spacer()

      // Status footer
      VStack(spacing: 12) {
        if isSetupComplete {
          HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
              .foregroundStyle(.green)
            if isQualityModelReady {
              Text(L10n.Setup.allSetQualityModel)
            } else if isQualityModelDownloading {
              Text(L10n.Setup.qualityModelDownloading)
            } else {
              Text(L10n.Setup.readyToUse)
            }
          }
          .font(.subheadline)
          .foregroundStyle(.green)
        } else {
          HStack(spacing: 8) {
            if isFastModelDownloading {
              ProgressView()
                .scaleEffect(0.7)
              Text(L10n.Setup.downloadingProgress(Int(fastDownloadProgress * 100)))
            } else if !isFastModelReady {
              Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
              Text(L10n.Setup.modelDownloadRequired)
            } else if !microphoneGranted {
              Image(systemName: "mic.slash")
                .foregroundStyle(.orange)
              Text(L10n.Setup.microphoneRequired)
            }
          }
          .font(.caption)
          .foregroundStyle(.secondary)

          if isFastModelDownloading {
            ProgressView(value: fastDownloadProgress)
              .progressViewStyle(.linear)
              .padding(.horizontal, 30)
          }
        }
      }
      .padding(.bottom, 20)
    }
    .padding(.horizontal, 10)
    .onAppear {
      checkCurrentPermissions()
    }
  }

  private func checkCurrentPermissions() {
    Task {
      microphoneGranted = await PermissionsManager.shared.checkMicrophonePermission()
      launchAtLoginEnabled = SettingsManager.shared.launchAtLogin
    }
  }

  private func startFastModelDownload() {
    guard !modelManager.hasDownloadedModel else { return }
    guard !modelManager.isDownloaded(fastModel),
      modelManager.isDownloading[fastModel] != true
    else {
      if isFastModelReady {
        startQualityModelDownload()
      }
      return
    }

    modelManager.downloadModel(fastModel)

    Task {
      await waitForFastModelThenStartQualityDownload()
    }
  }

  private func waitForFastModelThenStartQualityDownload() async {
    while modelManager.isDownloading[fastModel] == true {
      try? await Task.sleep(nanoseconds: 500_000_000)
    }

    if modelManager.isDownloaded(fastModel) {
      await MainActor.run {
        startQualityModelDownload()
      }
    }
  }

  private func startQualityModelDownload() {
    guard !modelManager.isDownloaded(qualityModel),
      modelManager.isDownloading[qualityModel] != true
    else {
      return
    }

    modelManager.downloadModel(qualityModel)
  }

  private func requestMicrophonePermission() {
    Task {
      let granted = await PermissionsManager.shared.requestMicrophonePermission()
      await MainActor.run {
        microphoneGranted = granted
        // Re-activate app after permission dialog closes to prevent window from going behind other apps
        NSApp.activate(ignoringOtherApps: true)
      }
    }
  }

  private func enableLaunchAtLogin() {
    SettingsManager.shared.configureLaunchAtLogin(enabled: true)
    launchAtLoginEnabled = true
  }
}

// MARK: - General Settings

struct GeneralSettingsView: View {
  private static let defaults = UserDefaults(suiteName: "work.voicey.Voicey") ?? .standard

  @AppStorage("launchAtLogin", store: defaults) private var launchAtLogin: Bool = false
  @AppStorage("showDockIcon", store: defaults) private var showDockIcon: Bool = false

  var body: some View {
    Form {
      Section(L10n.General.output) {
        Text(L10n.General.outputDescription)
          .font(.callout)
          .foregroundStyle(.secondary)

        Text(L10n.General.outputTip)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section {
        Toggle(L10n.General.launchAtLogin, isOn: $launchAtLogin)
          .onChange(of: launchAtLogin) { newValue in
            SettingsManager.shared.configureLaunchAtLogin(enabled: newValue)
          }

        Toggle(L10n.General.showDockIcon, isOn: $showDockIcon)
          .onChange(of: showDockIcon) { newValue in
            NSApp.setActivationPolicy(newValue ? .regular : .accessory)
          }
      }
    }
    .formStyle(.grouped)
    .padding()
  }
}

// MARK: - Hotkey Settings

struct HotkeySettingsView: View {
  var body: some View {
    Form {
      Section(L10n.Hotkey.transcriptionHotkey) {
        KeyboardShortcuts.Recorder(L10n.Hotkey.toggleRecording, name: .toggleTranscription)

        Text(L10n.Hotkey.hotkeyDescription)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section {
        Button(L10n.Hotkey.resetToDefault) {
          KeyboardShortcuts.reset(.toggleTranscription)
        }
      }

      Section(L10n.Hotkey.escapeKey) {
        Text(L10n.Hotkey.escapeDescription)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .padding()
  }
}

// MARK: - Audio Settings

struct AudioSettingsView: View {
  @State private var isTestingMic: Bool = false
  @State private var testLevel: Float = 0
  @State private var testPassed: Bool?

  var body: some View {
    Form {
      Section(L10n.Audio.inputDevice) {
        HStack {
          Text(L10n.Audio.microphone)
          Spacer()
          Text(AudioCaptureManager.defaultInputDevice?.localizedName ?? L10n.Audio.systemDefault)
            .foregroundStyle(.secondary)
        }

        Text(L10n.Audio.inputDeviceDescription)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section(L10n.Audio.testMicrophone) {
        HStack {
          Button(isTestingMic ? L10n.Audio.testing : L10n.Audio.testInput) {
            testMicrophone()
          }
          .disabled(isTestingMic)

          if isTestingMic {
            LevelMeterView(level: testLevel)
              .frame(width: 100, height: 16)
          }

          if let passed = testPassed {
            Image(systemName: passed ? "checkmark.circle.fill" : "xmark.circle.fill")
              .foregroundStyle(passed ? .green : .red)
          }
        }

        Text(L10n.Audio.testDescription)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .padding()
  }

  func testMicrophone() {
    isTestingMic = true
    testPassed = nil

    AudioLevelMonitor.testMicrophone(duration: 3.0) { level in
      testLevel = level
    } completion: { success in
      isTestingMic = false
      testPassed = success
    }
  }
}

// MARK: - Model Settings

struct ModelSettingsView: View {
  @ObservedObject var modelManager = ModelManager.shared
  private static let defaults = UserDefaults(suiteName: "work.voicey.Voicey") ?? .standard
  @AppStorage("selectedModel", store: defaults) private var selectedModel: String = WhisperModel.baseEn.rawValue

  var body: some View {
    Form {
      Section(L10n.Model.selectedModel) {
        Picker(L10n.Model.modelLabel, selection: $selectedModel) {
          ForEach(WhisperModel.allCases) { model in
            HStack {
              Text(model.displayName)
              if modelManager.isDownloaded(model) {
                Image(systemName: "checkmark.circle.fill")
                  .foregroundStyle(.green)
              }
            }
            .tag(model.rawValue)
          }
        }
        .pickerStyle(.menu)

        if let model = WhisperModel(rawValue: selectedModel) {
          Text(model.description)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      Section(L10n.Model.availableModels) {
        ForEach(WhisperModel.allCases) { model in
          ModelRowView(model: model)
        }
      }

      Section(L10n.Model.performance) {
        Text(L10n.Model.performanceDescription)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .padding()
  }
}

struct ModelRowView: View {
  let model: WhisperModel
  @ObservedObject var modelManager = ModelManager.shared
  @State private var deleteError: String?
  @State private var showDeleteError = false

  var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        HStack {
          Text(model.displayName)
            .font(.headline)

          if model.isRecommended {
            Text(L10n.Model.recommended)
              .font(.caption2)
              .fontWeight(.medium)
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(Color.blue.opacity(0.2))
              .foregroundStyle(.blue)
              .cornerRadius(4)
          }
        }
        Text(ModelManager.formatSize(model.diskSize))
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Spacer()

      if modelManager.isDownloading[model, default: false] {
        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)

          Button {
            modelManager.cancelDownload(model)
          } label: {
            Image(systemName: "xmark.circle")
          }
          .buttonStyle(.plain)
        }
      } else if modelManager.isDownloaded(model) {
        HStack(spacing: 8) {
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(.green)

          Button(L10n.Model.delete) {
            do {
              try modelManager.deleteModel(model)
            } catch {
              deleteError = error.localizedDescription
              showDeleteError = true
            }
          }
          .buttonStyle(.borderless)
          .foregroundStyle(.red)
        }
      } else {
        Button(L10n.Model.download) {
          modelManager.downloadModel(model)
        }
        .buttonStyle(.borderedProminent)
      }
    }
    .padding(.vertical, 4)
    .alert(L10n.Model.failedToDelete, isPresented: $showDeleteError) {
      Button(L10n.Model.ok, role: .cancel) {}
    } message: {
      Text(deleteError ?? L10n.Model.unknownError)
    }
  }
}

// MARK: - Voice Commands Settings

struct VoiceCommandsSettingsView: View {
  private static let defaults = UserDefaults(suiteName: "work.voicey.Voicey") ?? .standard
  @AppStorage("voiceCommandsEnabled", store: defaults) private var voiceCommandsEnabled: Bool = false
  @State private var commands: [VoiceCommand] = SettingsManager.shared.voiceCommands
  @State private var showAddCommand: Bool = false

  var body: some View {
    Form {
      Section {
        Toggle(L10n.VoiceCommands.enable, isOn: $voiceCommandsEnabled)

        Text(L10n.VoiceCommands.description)
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      if voiceCommandsEnabled {
        Section(L10n.VoiceCommands.commands) {
          ForEach($commands) { $command in
            VoiceCommandRow(command: $command)
          }
          .onDelete { indexSet in
            commands.remove(atOffsets: indexSet)
            saveCommands()
          }
        }

        Section {
          Button(L10n.VoiceCommands.addCustomCommand) {
            showAddCommand = true
          }

          Button(L10n.VoiceCommands.resetToDefaults) {
            commands = VoiceCommand.defaults
            saveCommands()
          }
          .foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.grouped)
    .padding()
    .sheet(isPresented: $showAddCommand) {
      AddVoiceCommandView { newCommand in
        commands.append(newCommand)
        saveCommands()
      }
    }
  }

  private func saveCommands() {
    SettingsManager.shared.voiceCommands = commands
  }
}

struct VoiceCommandRow: View {
  @Binding var command: VoiceCommand

  var body: some View {
    HStack {
      Toggle("", isOn: $command.enabled)
        .labelsHidden()

      VStack(alignment: .leading, spacing: 2) {
        TextField(L10n.VoiceCommands.phrase, text: $command.phrase)
          .textFieldStyle(.plain)
          .font(.headline)

        Text(actionDescription)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var actionDescription: String {
    switch command.action {
    case .newLine: return L10n.VoiceCommands.newLine
    case .newParagraph: return L10n.VoiceCommands.newParagraph
    case .scratchThat: return L10n.VoiceCommands.scratchThat
    case .custom(let text): return L10n.VoiceCommands.customText(text)
    }
  }
}

struct AddVoiceCommandView: View {
  @Environment(\.dismiss) var dismiss

  @State private var phrase: String = ""
  @State private var actionType: ActionType = .custom
  @State private var customText: String = ""

  var onAdd: (VoiceCommand) -> Void

  enum ActionType: CaseIterable {
    case newLine
    case newParagraph
    case custom

    var displayName: String {
      switch self {
      case .newLine: return L10n.VoiceCommands.actionNewLine
      case .newParagraph: return L10n.VoiceCommands.actionNewParagraph
      case .custom: return L10n.VoiceCommands.actionCustomText
      }
    }
  }

  var body: some View {
    VStack(spacing: 20) {
      Text(L10n.VoiceCommands.addVoiceCommand)
        .font(.headline)

      Form {
        TextField(L10n.VoiceCommands.triggerPhrase, text: $phrase)

        Picker(L10n.VoiceCommands.action, selection: $actionType) {
          ForEach(ActionType.allCases, id: \.self) { type in
            Text(type.displayName).tag(type)
          }
        }

        if actionType == .custom {
          TextField(L10n.VoiceCommands.customTextLabel, text: $customText)
        }
      }
      .formStyle(.grouped)

      HStack {
        Button(L10n.VoiceCommands.cancel) {
          dismiss()
        }
        .keyboardShortcut(.cancelAction)

        Button(L10n.VoiceCommands.add) {
          let action: VoiceCommandAction
          switch actionType {
          case .newLine: action = .newLine
          case .newParagraph: action = .newParagraph
          case .custom: action = .custom(customText)
          }

          let command = VoiceCommand(
            id: UUID(),
            phrase: phrase,
            action: action,
            enabled: true
          )
          onAdd(command)
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(phrase.isEmpty || (actionType == .custom && customText.isEmpty))
      }
    }
    .padding()
    .frame(width: 350, height: 280)
  }
}

// MARK: - Advanced Settings

struct AdvancedSettingsView: View {
  private static let defaults = UserDefaults(suiteName: "work.voicey.Voicey") ?? .standard
  @AppStorage("enableDetailedLogging", store: defaults) private var enableDetailedLogging: Bool = false
  @AppStorage("autoPasteEnabled", store: defaults) private var autoPasteEnabled: Bool = false
  @AppStorage("restoreClipboardAfterPaste", store: defaults) private var restoreClipboardAfterPaste: Bool = true
  @State private var accessibilityGranted = false
  @State private var clearError: String?
  @State private var showClearError = false
  #if VOICEY_DIRECT_DISTRIBUTION
  @ObservedObject private var sparkleUpdater = SparkleUpdater.shared
  #endif

  var body: some View {
    Form {
      #if VOICEY_DIRECT_DISTRIBUTION
      Section(L10n.Advanced.autoInsert) {
        Toggle(L10n.Advanced.autoInsertToggle, isOn: $autoPasteEnabled)
          .onChange(of: autoPasteEnabled) { enabled in
            guard enabled else { return }
            if !PermissionsManager.shared.checkAccessibilityPermission() {
              PermissionsManager.shared.promptForAccessibilityPermission()
            }
            checkAccessibility()
          }

        Text(
          autoPasteEnabled
            ? L10n.Advanced.autoInsertEnabledDesc
            : L10n.Advanced.autoInsertDisabledDesc
        )
        .font(.caption)
        .foregroundStyle(.secondary)

        if autoPasteEnabled {
          Toggle(L10n.Advanced.restoreClipboard, isOn: $restoreClipboardAfterPaste)

          Text(L10n.Advanced.restoreClipboardDesc)
            .font(.caption)
            .foregroundStyle(.secondary)

          // Accessibility permission status
          HStack {
            Text(L10n.Advanced.accessibilityPermission)
            Spacer()
            if accessibilityGranted {
              Label(L10n.Advanced.accessibilityGranted, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            } else {
              Button(L10n.Advanced.openSettings) {
                PermissionsManager.shared.promptForAccessibilityPermission()
              }
              .buttonStyle(.bordered)
            }
          }

          if !accessibilityGranted {
            Text(L10n.Advanced.accessibilityRequired)
              .font(.caption)
              .foregroundStyle(.orange)
          }
        }
      }
      #endif

      Section(L10n.Advanced.debugging) {
        Toggle(L10n.Advanced.enableDetailedLogging, isOn: $enableDetailedLogging)

        Text(L10n.Advanced.loggingDescription)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section(L10n.Advanced.data) {
        Button(L10n.Advanced.clearAllData, role: .destructive) {
          clearAllData()
        }

        Text(L10n.Advanced.clearDataDescription)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section(L10n.Advanced.about) {
        LabeledContent(
          L10n.Advanced.version,
          value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")
        LabeledContent(
          L10n.Advanced.build, value: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1")

        #if VOICEY_DIRECT_DISTRIBUTION
        LabeledContent(L10n.Advanced.distribution, value: L10n.Advanced.directInstall)

        Button(L10n.Advanced.checkForUpdates) {
          sparkleUpdater.checkForUpdates()
        }
        .disabled(!sparkleUpdater.canCheckForUpdates)

        Text(L10n.Advanced.updatesDeliveredFrom)
          .font(.caption)
          .foregroundStyle(.secondary)
        #else
        LabeledContent(L10n.Advanced.distribution, value: L10n.Advanced.appStore)
        #endif
      }
    }
    .formStyle(.grouped)
    .padding()
    .alert(L10n.Advanced.failedToClear, isPresented: $showClearError) {
      Button(L10n.Model.ok, role: .cancel) {}
    } message: {
      Text(clearError ?? L10n.Model.unknownError)
    }
    .onAppear {
      checkAccessibility()
    }
  }

  private func checkAccessibility() {
    accessibilityGranted = PermissionsManager.shared.checkAccessibilityPermission()
  }

  private func clearAllData() {
    var errors: [String] = []

    // Delete all models
    for model in WhisperModel.allCases {
      do {
        try ModelManager.shared.deleteModel(model)
      } catch {
        errors.append("\(model.displayName): \(error.localizedDescription)")
      }
    }

    // Reset settings
    SettingsManager.shared.resetToDefaults()

    if !errors.isEmpty {
      clearError = errors.joined(separator: "\n")
      showClearError = true
    }
  }
}

// MARK: - Setup Step Row

/// Setup step row with progress support
struct SetupStepRow: View {
  let stepNumber: Int
  let icon: String
  let title: String
  let description: String
  let isComplete: Bool
  var isInProgress: Bool = false
  var progress: Double = 0
  var isOptional: Bool = false
  let buttonTitle: String
  let action: () -> Void

  var body: some View {
    HStack(spacing: 16) {
      // Step number / status indicator
      ZStack {
        Circle()
          .fill(
            isComplete
              ? Color.green.opacity(0.15)
              : (isInProgress ? Color.blue.opacity(0.15) : Color.gray.opacity(0.1))
          )
          .frame(width: 44, height: 44)

        if isComplete {
          Image(systemName: "checkmark")
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(.green)
        } else if isInProgress {
          if progress > 0 {
            // Circular progress
            Circle()
              .stroke(Color.blue.opacity(0.3), lineWidth: 3)
              .frame(width: 30, height: 30)
            Circle()
              .trim(from: 0, to: progress)
              .stroke(Color.blue, style: StrokeStyle(lineWidth: 3, lineCap: .round))
              .frame(width: 30, height: 30)
              .rotationEffect(.degrees(-90))
          } else {
            ProgressView()
              .scaleEffect(0.8)
          }
        } else {
          Text("\(stepNumber)")
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(.secondary)
        }
      }

      // Text
      VStack(alignment: .leading, spacing: 2) {
        HStack {
          Text(title)
            .font(.headline)
            .foregroundStyle(isComplete ? .secondary : .primary)

          if isOptional {
            Text(L10n.Setup.optional)
              .font(.caption2)
              .foregroundStyle(.secondary)
              .padding(.horizontal, 5)
              .padding(.vertical, 2)
              .background(Color.secondary.opacity(0.2))
              .cornerRadius(3)
          }
        }

        Text(description)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Spacer()

      // Button
      Button(action: action) {
        Text(buttonTitle)
          .font(.subheadline)
      }
      .buttonStyle(.bordered)
      .disabled(isComplete || isInProgress)
    }
    .padding(.vertical, 10)
    .padding(.horizontal, 12)
    .background(
      RoundedRectangle(cornerRadius: 10)
        .fill(isComplete ? Color.green.opacity(0.05) : Color.clear)
    )
  }
}

// MARK: - Preview

#Preview {
  SettingsView()
    .environmentObject(AppState())
}
