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
          Label("Setup", systemImage: "checkmark.circle")
        }
        .tag(Tab.setup)

      GeneralSettingsView()
        .tabItem {
          Label("General", systemImage: "gear")
        }
        .tag(Tab.general)

      HotkeySettingsView()
        .tabItem {
          Label("Hotkey", systemImage: "keyboard")
        }
        .tag(Tab.hotkey)

      AudioSettingsView()
        .tabItem {
          Label("Audio", systemImage: "mic")
        }
        .tag(Tab.audio)

      ModelSettingsView()
        .tabItem {
          Label("Model", systemImage: "cpu")
        }
        .tag(Tab.model)

      VoiceCommandsSettingsView()
        .tabItem {
          Label("Voice Commands", systemImage: "text.bubble")
        }
        .tag(Tab.voiceCommands)

      AdvancedSettingsView()
        .tabItem {
          Label("Advanced", systemImage: "wrench.and.screwdriver")
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

  /// The fast model to download first for quick startup
  private let fastModel = WhisperModel.base

  /// The high-quality model to download in background
  private let qualityModel = WhisperModel.largeTurbo

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

        Text("Voicey")
          .font(.title2)
          .fontWeight(.bold)

        Text("Voice-to-text transcription for macOS")
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
          title: "Download Model",
          description: "Any model works. Default: \(fastModel.displayName) (~80MB)",
          isComplete: isFastModelReady,
          isInProgress: isFastModelDownloading,
          progress: fastDownloadProgress,
          buttonTitle: isFastModelReady
            ? "Ready" : (isFastModelDownloading ? "Downloading..." : "Download"),
          action: startFastModelDownload
        )

        // Step 1b: Quality Model Download (optional upgrade)
        SetupStepRow(
          stepNumber: 0,
          icon: "sparkles",
          title: "Download Quality Model",
          description: "\(qualityModel.displayName) (~1.5GB) - Better accuracy",
          isComplete: isQualityModelReady,
          isInProgress: isQualityModelDownloading,
          progress: qualityDownloadProgress,
          isOptional: true,
          buttonTitle: isQualityModelReady
            ? "Ready"
            : (isQualityModelDownloading
              ? "Downloading..." : (isFastModelReady ? "Download" : "After fast model")),
          action: startQualityModelDownload
        )
        .disabled(!isFastModelReady && !isQualityModelDownloading)
        .opacity(isFastModelReady || isQualityModelDownloading || isQualityModelReady ? 1.0 : 0.6)

        // Step 2: Microphone
        SetupStepRow(
          stepNumber: 2,
          icon: "mic.fill",
          title: "Microphone Access",
          description: "Required to hear your voice",
          isComplete: microphoneGranted,
          buttonTitle: microphoneGranted ? "Granted" : "Allow",
          action: requestMicrophonePermission
        )

        // Step 3: Launch at Login (optional)
        SetupStepRow(
          stepNumber: 3,
          icon: "arrow.clockwise",
          title: "Launch at Login",
          description: "Start automatically (optional)",
          isComplete: launchAtLoginEnabled,
          isOptional: true,
          buttonTitle: launchAtLoginEnabled ? "Enabled" : "Enable",
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
              Text("All set! Using quality model.")
            } else if isQualityModelDownloading {
              Text("Ready! Quality model downloading...")
            } else {
              Text("Ready to use!")
            }
          }
          .font(.subheadline)
          .foregroundStyle(.green)
        } else {
          HStack(spacing: 8) {
            if isFastModelDownloading {
              ProgressView()
                .scaleEffect(0.7)
              Text("Downloading model... \(Int(fastDownloadProgress * 100))%")
            } else if !isFastModelReady {
              Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
              Text("Model download required")
            } else if !microphoneGranted {
              Image(systemName: "mic.slash")
                .foregroundStyle(.orange)
              Text("Microphone access required")
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
      Section("Output") {
        Text("Voicey copies transcriptions to your clipboard. Press ⌘V to paste.")
          .font(.callout)
          .foregroundStyle(.secondary)

        Text("💡 Enable auto-insert in Advanced settings to paste directly into text fields.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section {
        Toggle("Launch at Login", isOn: $launchAtLogin)
          .onChange(of: launchAtLogin) { newValue in
            SettingsManager.shared.configureLaunchAtLogin(enabled: newValue)
          }

        Toggle("Show Dock Icon", isOn: $showDockIcon)
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
      Section("Transcription Hotkey") {
        KeyboardShortcuts.Recorder("Toggle Recording:", name: .toggleTranscription)

        Text("Press this hotkey to start recording. Press again to stop and transcribe.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section {
        Button("Reset to Default (⌃V)") {
          KeyboardShortcuts.reset(.toggleTranscription)
        }
      }

      Section("Escape Key") {
        Text("Press ESC while recording to cancel without transcribing.")
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
      Section("Input Device") {
        HStack {
          Text("Microphone")
          Spacer()
          Text(AudioCaptureManager.defaultInputDevice?.localizedName ?? "System Default")
            .foregroundStyle(.secondary)
        }

        Text("Voicey uses your system's default audio input device.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section("Test Microphone") {
        HStack {
          Button(isTestingMic ? "Testing..." : "Test Input") {
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

        Text("Speak into your microphone to verify it's working.")
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
  @AppStorage("selectedModel", store: defaults) private var selectedModel: String = WhisperModel.base.rawValue

  var body: some View {
    Form {
      Section("Selected Model") {
        Picker("Model", selection: $selectedModel) {
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

      Section("Available Models") {
        ForEach(WhisperModel.allCases) { model in
          ModelRowView(model: model)
        }
      }

      Section("Performance") {
        Text("GPU acceleration is automatically enabled via Metal on Apple Silicon.")
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
            Text("Recommended")
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

          Button("Delete") {
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
        Button("Download") {
          modelManager.downloadModel(model)
        }
        .buttonStyle(.borderedProminent)
      }
    }
    .padding(.vertical, 4)
    .alert("Failed to Delete Model", isPresented: $showDeleteError) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(deleteError ?? "Unknown error")
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
        Toggle("Enable Voice Commands", isOn: $voiceCommandsEnabled)

        Text(
          "When enabled, specific phrases will trigger actions instead of being transcribed as text."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      if voiceCommandsEnabled {
        Section("Commands") {
          ForEach($commands) { $command in
            VoiceCommandRow(command: $command)
          }
          .onDelete { indexSet in
            commands.remove(atOffsets: indexSet)
            saveCommands()
          }
        }

        Section {
          Button("Add Custom Command") {
            showAddCommand = true
          }

          Button("Reset to Defaults") {
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
        TextField("Phrase", text: $command.phrase)
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
    case .newLine: return "Insert new line"
    case .newParagraph: return "Insert new paragraph"
    case .scratchThat: return "Delete last utterance"
    case .custom(let text): return "Insert: \(text)"
    }
  }
}

struct AddVoiceCommandView: View {
  @Environment(\.dismiss) var dismiss

  @State private var phrase: String = ""
  @State private var actionType: ActionType = .custom
  @State private var customText: String = ""

  var onAdd: (VoiceCommand) -> Void

  enum ActionType: String, CaseIterable {
    case newLine = "New Line"
    case newParagraph = "New Paragraph"
    case custom = "Custom Text"
  }

  var body: some View {
    VStack(spacing: 20) {
      Text("Add Voice Command")
        .font(.headline)

      Form {
        TextField("Trigger Phrase", text: $phrase)

        Picker("Action", selection: $actionType) {
          ForEach(ActionType.allCases, id: \.self) { type in
            Text(type.rawValue).tag(type)
          }
        }

        if actionType == .custom {
          TextField("Custom Text", text: $customText)
        }
      }
      .formStyle(.grouped)

      HStack {
        Button("Cancel") {
          dismiss()
        }
        .keyboardShortcut(.cancelAction)

        Button("Add") {
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
      Section("Auto-Insert") {
        Toggle("Auto-insert after transcription", isOn: $autoPasteEnabled)
          .onChange(of: autoPasteEnabled) { enabled in
            guard enabled else { return }
            if !PermissionsManager.shared.checkAccessibilityPermission() {
              PermissionsManager.shared.promptForAccessibilityPermission()
            }
            checkAccessibility()
          }

        Text(
          autoPasteEnabled
            ? "Voicey will attempt to insert text directly into the focused text field."
            : "Voicey copies transcriptions to your clipboard. Press ⌘V to paste."
        )
        .font(.caption)
        .foregroundStyle(.secondary)

        if autoPasteEnabled {
          Toggle("Restore clipboard after paste", isOn: $restoreClipboardAfterPaste)

          Text("When enabled, restores your original clipboard after pasting transcription.")
            .font(.caption)
            .foregroundStyle(.secondary)

          // Accessibility permission status
          HStack {
            Text("Accessibility Permission")
            Spacer()
            if accessibilityGranted {
              Label("Granted", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            } else {
              Button("Open Settings") {
                PermissionsManager.shared.promptForAccessibilityPermission()
              }
              .buttonStyle(.bordered)
            }
          }

          if !accessibilityGranted {
            Text("Accessibility permission is required for auto-insert to work.")
              .font(.caption)
              .foregroundStyle(.orange)
          }
        }
      }
      #endif

      Section("Debugging") {
        Toggle("Enable Detailed Logging", isOn: $enableDetailedLogging)

        Text("Logs additional information for troubleshooting. May impact performance.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section("Data") {
        Button("Clear All Data", role: .destructive) {
          clearAllData()
        }

        Text("Removes all downloaded models and resets settings to defaults.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section("About") {
        LabeledContent(
          "Version",
          value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")
        LabeledContent(
          "Build", value: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1")

        #if VOICEY_DIRECT_DISTRIBUTION
        LabeledContent("Distribution", value: "Direct Install")

        Button("Check for Updates") {
          sparkleUpdater.checkForUpdates()
        }
        .disabled(!sparkleUpdater.canCheckForUpdates)

        Text("Updates are delivered directly from voicy.work")
          .font(.caption)
          .foregroundStyle(.secondary)
        #else
        LabeledContent("Distribution", value: "App Store")
        #endif
      }
    }
    .formStyle(.grouped)
    .padding()
    .alert("Failed to Clear Data", isPresented: $showClearError) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(clearError ?? "Unknown error")
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
            Text("Optional")
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
