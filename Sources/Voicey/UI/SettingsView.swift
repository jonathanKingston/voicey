import AVFoundation
import AppKit
import KeyboardShortcuts
import SwiftUI
import VoiceyCore

// Settings UI aggregates many panes in one file. Keep the file-length warning
// disabled until the panes are extracted into separate views.
// swiftlint:disable file_length

/// Main settings view with sidebar navigation
struct SettingsView: View {
  static let windowSize = CGSize(width: 760, height: 580)

  private static let sidebarMinWidth: CGFloat = 190
  private static let sidebarIdealWidth: CGFloat = 210
  private static let sidebarMaxWidth: CGFloat = 240

  enum Tab: String, CaseIterable, Hashable, Identifiable {
    case setup, general, hotkey, audio, model, transcription, voiceCommands, advanced

    var id: Self { self }

    var title: String {
      switch self {
      case .setup:
        return L10n.Settings.setup
      case .general:
        return L10n.Settings.general
      case .hotkey:
        return L10n.Settings.hotkey
      case .audio:
        return L10n.Settings.audio
      case .model:
        return L10n.Settings.model
      case .transcription:
        return L10n.Settings.transcription
      case .voiceCommands:
        return L10n.Settings.voiceCommands
      case .advanced:
        return L10n.Settings.advanced
      }
    }

    var iconName: String {
      switch self {
      case .setup:
        return "sparkles"
      case .general:
        return "slider.horizontal.3"
      case .hotkey:
        return "command"
      case .audio:
        return "mic.fill"
      case .model:
        return "waveform"
      case .transcription:
        return "text.book.closed.fill"
      case .voiceCommands:
        return "text.bubble.fill"
      case .advanced:
        return "gearshape.2.fill"
      }
    }
  }

  @State private var selectedTab: Tab? = .setup
  @ObservedObject private var modelManager = ModelManager.shared
  @State private var microphoneGranted = false

  init(initialTab: Tab? = nil) {
    _selectedTab = State(initialValue: initialTab ?? .setup)
  }

  /// Whether setup is complete (model downloaded + mic permission)
  private var isSetupComplete: Bool {
    microphoneGranted && modelManager.hasDownloadedModel
  }

  private var defaultTab: Tab {
    isSetupComplete ? .general : .setup
  }

  var body: some View {
    NavigationSplitView {
      List(selection: $selectedTab) {
        if !isSetupComplete {
          sidebarSection(tabs: [.setup])
          sidebarSection(tabs: Tab.allCases.filter { $0 != .setup })
        } else {
          sidebarSection(tabs: Tab.allCases)
        }
      }
      .listStyle(.sidebar)
      .navigationSplitViewColumnWidth(
        min: Self.sidebarMinWidth,
        ideal: Self.sidebarIdealWidth,
        max: Self.sidebarMaxWidth
      )
      .scrollContentBackground(.hidden)
      .background(.ultraThinMaterial)
    } detail: {
      settingsDetail(for: selectedTab ?? defaultTab)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial)
    }
    .frame(width: Self.windowSize.width, height: Self.windowSize.height)
    .background(.thinMaterial)
    .task {
      microphoneGranted = await PermissionsManager.shared.checkMicrophonePermission()
      if selectedTab == nil || (selectedTab == .setup && isSetupComplete) {
        selectedTab = defaultTab
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .voiceyOpenSettingsTab)) { notification in
      guard
        let rawValue = notification.object as? String,
        let requestedTab = Tab(rawValue: rawValue)
      else { return }
      selectedTab = requestedTab
    }
  }

  @ViewBuilder
  private func sidebarSection(tabs: [Tab]) -> some View {
    Section {
      ForEach(tabs) { tab in
        SettingsSidebarRow(tab: tab, isSelected: selectedTab == tab)
          .tag(tab)
          .listRowBackground(Color.clear)
          .listRowSeparator(.hidden)
          .listRowInsets(EdgeInsets(top: 2, leading: 10, bottom: 2, trailing: 10))
      }
    }
  }

  @ViewBuilder
  private func settingsDetail(for tab: Tab) -> some View {
    switch tab {
    case .setup:
      SetupSettingsView()
    case .general:
      GeneralSettingsView()
    case .hotkey:
      HotkeySettingsView()
    case .audio:
      AudioSettingsView()
    case .model:
      ModelSettingsView()
    case .transcription:
      TranscriptionSteeringSettingsView()
    case .voiceCommands:
      VoiceCommandsSettingsView()
    case .advanced:
      AdvancedSettingsView()
    }
  }
}

extension Notification.Name {
  static let voiceyOpenSettingsTab = Notification.Name("voiceyOpenSettingsTab")
}

private struct SettingsSidebarRow: View {
  let tab: SettingsView.Tab
  let isSelected: Bool

  private var foregroundColor: Color {
    isSelected ? .primary : .secondary
  }

  var body: some View {
    Label {
      Text(tab.title)
        .font(.system(size: 13, weight: .regular))
        .lineLimit(1)
    } icon: {
      Image(systemName: tab.iconName)
        .frame(width: 16)
    }
    .foregroundStyle(foregroundColor)
    .padding(.vertical, 8)
    .padding(.horizontal, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

// MARK: - Setup Settings (Onboarding-style status view)

struct SetupSettingsView: View {
  @State private var microphoneGranted = false
  @State private var launchAtLoginEnabled = false

  @ObservedObject private var modelManager = ModelManager.shared

  /// The recommended model to download first
  private let defaultModel = ModelManager.defaultModel

  private var defaultModelIcon: String {
    switch defaultModel {
    case .qwen3Small:
      return "globe"
    case .qwen3Large:
      return "sparkles.rectangle.stack"
    default:
      return "cpu"
    }
  }

  /// Whether all required setup is complete
  private var isSetupComplete: Bool {
    microphoneGranted && modelManager.hasDownloadedModel
  }

  /// Whether default model is currently downloading
  private var isDefaultModelDownloading: Bool {
    modelManager.isDownloading[defaultModel] == true
  }

  /// Whether default model is ready
  private var isDefaultModelReady: Bool {
    modelManager.isDownloaded(defaultModel)
  }

  /// Download progress for default model (0-1)
  private var defaultDownloadProgress: Double {
    modelManager.downloadProgress[defaultModel] ?? 0
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
      .padding(.bottom, 8)

      // Setup steps
      VStack(spacing: 10) {
        // Step 1: Default model download
        SetupStepRow(
          stepNumber: 1,
          icon: defaultModelIcon,
          title: L10n.Setup.downloadModel,
          description: L10n.Setup.downloadModelDesc(defaultModel.displayName),
          isComplete: isDefaultModelReady,
          isInProgress: isDefaultModelDownloading,
          progress: defaultDownloadProgress,
          buttonTitle: isDefaultModelReady
            ? L10n.Setup.ready
            : (isDefaultModelDownloading ? L10n.Setup.downloading : L10n.Setup.download),
          action: startDefaultModelDownload
        )

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
      .padding(.top, 16)

      Spacer()

      // Status footer
      VStack(spacing: 12) {
        if isSetupComplete {
          HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
              .foregroundStyle(.green)
            Text(L10n.Setup.readyToUse)
          }
          .font(.subheadline)
          .foregroundStyle(.green)
        } else {
          HStack(spacing: 8) {
            if isDefaultModelDownloading {
              ProgressView()
                .scaleEffect(0.7)
              Text(L10n.Setup.downloadingProgress(Int(defaultDownloadProgress * 100)))
            } else if !modelManager.hasDownloadedModel {
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

          if let downloadError = modelManager.downloadError, !downloadError.isEmpty {
            Label(downloadError, systemImage: "exclamationmark.triangle.fill")
              .font(.caption2)
              .foregroundStyle(.red)
              .multilineTextAlignment(.center)
              .padding(.horizontal, 20)
          }

          if isDefaultModelDownloading {
            ProgressView(value: defaultDownloadProgress)
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

  private func startDefaultModelDownload() {
    guard !modelManager.isDownloaded(defaultModel),
      modelManager.isDownloading[defaultModel] != true
    else {
      return
    }

    modelManager.downloadModel(defaultModel)
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
    SettingsManager.shared.launchAtLogin = true
    launchAtLoginEnabled = true
  }
}

// MARK: - General Settings

struct GeneralSettingsView: View {
  private static let defaults = SettingsManager.defaultsStore

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
          .onChange(of: launchAtLogin) {
            SettingsManager.shared.configureLaunchAtLogin(enabled: launchAtLogin)
          }

        Toggle(L10n.General.showDockIcon, isOn: $showDockIcon)
          .onChange(of: showDockIcon) {
            NSApp.setActivationPolicy(showDockIcon ? .regular : .accessory)
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
        LabeledContent(L10n.Hotkey.toggleRecording) {
          KeybindingRecorderView(name: .toggleTranscription)
        }

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
  private static let defaults = SettingsManager.defaultsStore
  @AppStorage("recordingMode", store: defaults) private var recordingMode: String =
    RecordingMode.manual.rawValue
  @State private var isTestingMic: Bool = false
  @State private var testLevel: Float = 0
  @State private var testPassed: Bool?

  var body: some View {
    Form {
      Section(L10n.Audio.recordingMode) {
        Picker(L10n.Audio.recordingMode, selection: $recordingMode) {
          Text(L10n.Audio.recordingModeManual)
            .tag(RecordingMode.manual.rawValue)
          Text(L10n.Audio.recordingModeHandsFree)
            .tag(RecordingMode.handsFree.rawValue)
        }
        .pickerStyle(.segmented)

        Text(L10n.Audio.recordingModeDescription)
          .font(.caption)
          .foregroundStyle(.secondary)

        let currentMode = RecordingMode(rawValue: recordingMode) ?? .manual
        Text(
          currentMode == .manual
            ? L10n.Audio.recordingModeManualDescription
            : L10n.Audio.recordingModeHandsFreeDescription
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

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
  @EnvironmentObject private var appState: AppState
  @ObservedObject var modelManager = ModelManager.shared
  private static let defaults = SettingsManager.defaultsStore
  @AppStorage("selectedModel", store: defaults) private var selectedModel: String = ModelManager
    .defaultModel.rawValue

  var body: some View {
    Form {
      Section(L10n.Model.selectedModel) {
        Picker(L10n.Model.modelLabel, selection: $selectedModel) {
          ForEach(SpeechModel.userFacingModels) { model in
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

        if let model = SpeechModel(rawValue: selectedModel) {
          Text(model.description)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      Section(L10n.Model.availableModels) {
        ForEach(SpeechModel.userFacingModels) { model in
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
    .onAppear {
      modelManager.loadDownloadedModels()
      if !SpeechModel.userFacingModels.contains(where: { $0.rawValue == selectedModel }) {
        selectedModel = ModelManager.defaultModel.rawValue
      }
      modelManager.checkForUpdatesForDownloadedModels()
      if let model = SpeechModel(rawValue: selectedModel) {
        appState.currentModel = model
      }
    }
    .onChange(of: selectedModel) {
      guard let model = SpeechModel(rawValue: selectedModel) else { return }
      appState.currentModel = model
      NotificationCenter.default.post(name: .voiceySelectedModelDidChange, object: model)
    }
  }
}

// MARK: - Transcription steering (glossary & screen context)

struct TranscriptionSteeringSettingsView: View {
  private static let defaults = SettingsManager.defaultsStore
  @AppStorage("transcriptionGlossaryEnabled", store: defaults) private
    var transcriptionGlossaryEnabled = true
  @AppStorage("transcriptionScreenContextEnabled", store: defaults) private
    var transcriptionScreenContextEnabled = true
  @AppStorage("transcriptionScreenContextOCREnabled", store: defaults) private
    var transcriptionScreenContextOCREnabled = false
  @State private var transcriptionGlossary = SettingsManager.shared.transcriptionGlossary
  @State private var screenCaptureGranted = PermissionsManager.shared.checkScreenCapturePermission()

  var body: some View {
    Form {
      Section {
        Text(L10n.Transcription.intro)
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      Section(L10n.Transcription.customVocabulary) {
        Toggle(L10n.Transcription.glossaryEnable, isOn: $transcriptionGlossaryEnabled)

        Text(L10n.Transcription.glossaryDescription)
          .font(.caption)
          .foregroundStyle(.secondary)

        if transcriptionGlossaryEnabled {
          MonospacedGlossaryEditor(
            text: $transcriptionGlossary,
            placeholder: L10n.Transcription.glossaryPlaceholder
          )
        }
      }

      Section(L10n.Transcription.onScreenText) {
        Toggle(L10n.Transcription.screenContextEnable, isOn: $transcriptionScreenContextEnabled)

        Text(L10n.Transcription.screenContextDescription)
          .font(.caption)
          .foregroundStyle(.secondary)

        if transcriptionScreenContextEnabled {
          Toggle(
            L10n.Transcription.screenContextOCREnable, isOn: $transcriptionScreenContextOCREnabled
          )
          .onChange(of: transcriptionScreenContextOCREnabled) { _, enabled in
            if enabled, !PermissionsManager.shared.checkScreenCapturePermission() {
              _ = PermissionsManager.shared.requestScreenCapturePermission()
            }
            screenCaptureGranted = PermissionsManager.shared.checkScreenCapturePermission()
          }

          Text(L10n.Transcription.screenContextOCRDescription)
            .font(.caption)
            .foregroundStyle(.secondary)

          if transcriptionScreenContextOCREnabled, !screenCaptureGranted {
            Text(L10n.Transcription.screenContextOCRPermission)
              .font(.caption)
              .foregroundStyle(.orange)
            Button(L10n.Transcription.openScreenCaptureSettings) {
              PermissionsManager.shared.openScreenCaptureSettings()
            }
          }
        }
      }
    }
    .formStyle(.grouped)
    .padding()
    .onAppear {
      transcriptionGlossary = SettingsManager.shared.transcriptionGlossary
      screenCaptureGranted = PermissionsManager.shared.checkScreenCapturePermission()
    }
    .onChange(of: transcriptionGlossary) {
      SettingsManager.shared.transcriptionGlossary = transcriptionGlossary
    }
    .onDisappear {
      SettingsManager.shared.transcriptionGlossary = transcriptionGlossary
    }
  }
}

struct ModelRowView: View {
  let model: SpeechModel
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

        if let updateStatusText {
          Text(updateStatusText)
            .font(.caption2)
            .foregroundStyle(updateStatusColor)
        }
      }

      Spacer()

      if modelManager.isUpdating[model, default: false] {
        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)

          Text(L10n.Model.updating)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      } else if modelManager.isDownloading[model, default: false] {
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

          updateActionButton

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

  @ViewBuilder
  private var updateActionButton: some View {
    if case .checking = modelUpdateStatus {
      ProgressView()
        .controlSize(.small)
    } else if shouldOfferUpdate {
      Button(L10n.Model.update) {
        modelManager.updateDownloadedModel(model)
      }
      .buttonStyle(.borderless)
    } else {
      Button(L10n.Model.checkForUpdates) {
        modelManager.checkForModelUpdate(model)
      }
      .buttonStyle(.borderless)
    }
  }

  private var modelUpdateStatus: ModelUpdateStatus? {
    modelManager.modelUpdateStatus[model]
  }

  private var shouldOfferUpdate: Bool {
    if !modelManager.hasKnownRevision(for: model) { return true }
    if case .updateAvailable = modelUpdateStatus { return true }
    return false
  }

  private var updateStatusText: String? {
    guard modelManager.isDownloaded(model) else { return nil }

    if !modelManager.hasKnownRevision(for: model) {
      return L10n.Model.revisionUnknown
    }

    switch modelUpdateStatus {
    case .some(.checking):
      return L10n.Model.checkingForModelUpdates
    case .some(.upToDate):
      return L10n.Model.upToDate
    case .some(.updateAvailable):
      return L10n.Model.updateAvailable
    case .some(.failed(let message)):
      return message
    case .none:
      return nil
    }
  }

  private var updateStatusColor: Color {
    if !modelManager.hasKnownRevision(for: model) {
      return .orange
    }

    switch modelUpdateStatus {
    case .some(.updateAvailable):
      return .orange
    case .some(.failed):
      return .red
    default:
      return .secondary
    }
  }
}

// MARK: - Voice Commands Settings

struct VoiceCommandsSettingsView: View {
  private static let defaults = SettingsManager.defaultsStore
  @AppStorage("voiceCommandsEnabled", store: defaults) private var voiceCommandsEnabled: Bool =
    false
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
            VoiceCommandRow(command: $command) {
              deleteCommand(id: command.id)
            }
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
    .onChange(of: commands) {
      saveCommands()
    }
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

  private func deleteCommand(id: UUID) {
    commands.removeAll { $0.id == id }
    saveCommands()
  }
}

struct VoiceCommandRow: View {
  @Binding var command: VoiceCommand
  var onDelete: () -> Void

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      Toggle("", isOn: $command.enabled)
        .labelsHidden()
        .frame(width: 44, alignment: .leading)

      VStack(alignment: .leading, spacing: 2) {
        TextField("", text: $command.phrase, prompt: Text(L10n.VoiceCommands.phrase))
          .textFieldStyle(.plain)
          .font(.headline)
          .labelsHidden()

        Text(actionDescription)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      Button(role: .destructive, action: onDelete) {
        Image(systemName: "trash")
      }
      .buttonStyle(.borderless)
      .foregroundStyle(.red)
      .frame(width: 24, alignment: .trailing)
      .accessibilityLabel(L10n.Model.delete)
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
  private static let defaults = SettingsManager.defaultsStore
  @AppStorage("enableDetailedLogging", store: defaults) private var enableDetailedLogging: Bool =
    false
  @AppStorage("autoPasteEnabled", store: defaults) private var autoPasteEnabled: Bool = false
  @AppStorage("restoreClipboardAfterPaste", store: defaults) private var restoreClipboardAfterPaste:
    Bool = true
  @AppStorage("pauseMediaDuringTranscription", store: defaults)
  private var pauseMediaDuringTranscription: Bool = true
  @State private var accessibilityGranted = false
  @State private var clearError: String?
  @State private var showClearError = false
  @State private var runtimeDiagnosticsCopied = false
  #if VOICEY_DIRECT_DISTRIBUTION
    @ObservedObject private var sparkleUpdater = SparkleUpdater.shared
  #endif

  var body: some View {
    Form {
      Section(L10n.Advanced.mediaPlayback) {
        Toggle(L10n.Advanced.pauseMediaDuringTranscription, isOn: $pauseMediaDuringTranscription)

        Text(L10n.Advanced.pauseMediaDuringTranscriptionDesc)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section(L10n.Advanced.autoInsert) {
        Toggle(L10n.Advanced.autoInsertToggle, isOn: $autoPasteEnabled)
          .onChange(of: autoPasteEnabled) {
            guard autoPasteEnabled else { return }
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

      Section(L10n.Advanced.debugging) {
        Button(L10n.Advanced.copyRuntimeDiagnostics) {
          copyRuntimeDiagnosticsToPasteboard()
        }

        if runtimeDiagnosticsCopied {
          Text(L10n.Advanced.runtimeDiagnosticsCopied)
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
          Text(L10n.Advanced.runtimeDiagnosticsDescription)
            .font(.caption)
            .foregroundStyle(.secondary)
        }

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
          L10n.Advanced.build,
          value: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1")

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

  private func copyRuntimeDiagnosticsToPasteboard() {
    Task {
      let model = SettingsManager.shared.selectedModel
      let inferReady = await VoiceyRuntimeSupervisor.shared.isInferReady
      let report = VoiceyRuntimeDiagnostics.diagnosticReport(
        selectedModel: model,
        inferReady: inferReady
      )
      await MainActor.run {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        runtimeDiagnosticsCopied = true
      }
    }
  }

  private func clearAllData() {
    var errors: [String] = []

    // Delete all models
    for model in SpeechModel.allCases {
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
