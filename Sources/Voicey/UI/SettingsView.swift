import AVFoundation
import KeyboardShortcuts
import SwiftUI

/// Main settings view with tabbed interface
struct SettingsView: View {
  var body: some View {
    TabView {
      GeneralSettingsView()
        .tabItem {
          Label("General", systemImage: "gear")
        }

      HotkeySettingsView()
        .tabItem {
          Label("Hotkey", systemImage: "keyboard")
        }

      AudioSettingsView()
        .tabItem {
          Label("Audio", systemImage: "mic")
        }

      ModelSettingsView()
        .tabItem {
          Label("Model", systemImage: "cpu")
        }

      VoiceCommandsSettingsView()
        .tabItem {
          Label("Voice Commands", systemImage: "text.bubble")
        }

      AdvancedSettingsView()
        .tabItem {
          Label("Advanced", systemImage: "wrench.and.screwdriver")
        }
    }
    .frame(width: 500, height: 400)
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

// MARK: - Preview

#Preview {
  SettingsView()
    .environmentObject(AppState())
}
