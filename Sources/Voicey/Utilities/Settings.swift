import Foundation
import ServiceManagement
import VoiceyCore
import os

enum RecordingMode: String, CaseIterable, Sendable {
  case manual
  case handsFree
}

/// Manages user settings and preferences
final class SettingsManager: SettingsProviding, @unchecked Sendable {
  static let shared = SettingsManager()

  /// Use standard defaults for bundled apps and an explicit suite only when the
  /// process has no bundle identifier (for example, a raw SwiftPM binary).
  private let defaults: UserDefaults
  #if VOICEY_DIRECT_DISTRIBUTION
    private static let fallbackSuiteName = "work.voicey.VoiceyDirect"
  #else
    private static let fallbackSuiteName = "work.voicey.Voicey"
  #endif

  static var defaultsStore: UserDefaults {
    if Bundle.main.bundleIdentifier != nil {
      return .standard
    }
    return UserDefaults(suiteName: Self.fallbackSuiteName) ?? .standard
  }

  private init() {
    defaults = Self.defaultsStore
    registerDefaults()
  }

  private func registerDefaults() {
    defaults.register(defaults: [
      // Default to the recommended native Qwen3 model for this machine.
      Keys.selectedModel: ModelManager.defaultModel.rawValue,
      Keys.launchAtLogin: false,
      Keys.showDockIcon: false,
      Keys.recordingMode: RecordingMode.manual.rawValue,
      Keys.autoPasteEnabled: false,  // Disabled by default - advanced feature requiring Accessibility
      Keys.restoreClipboardAfterPaste: true,  // Restore original clipboard after paste
      Keys.pauseMediaDuringTranscription: true,
      Keys.voiceCommandsEnabled: false,
      Keys.transcriptionGlossaryEnabled: true,
      Keys.transcriptionScreenContextEnabled: true,
      Keys.transcriptionScreenContextOCREnabled: false,
      Keys.transcriptionLanguageID: TranscriptionQwenLanguage.autoOption.id,
      Keys.enableDetailedLogging: false,
      Keys.hasCompletedOnboarding: false,
      Keys.keepDictationHistoryLocally: false
    ])
  }

  // MARK: - Keys

  private enum Keys {
    static let selectedModel = "selectedModel"
    static let lastSeenDefaultModel = "lastSeenDefaultModel"
    static let lastAppliedDefaultModel = "lastAppliedDefaultModel"
    static let launchAtLogin = "launchAtLogin"
    static let showDockIcon = "showDockIcon"
    static let recordingMode = "recordingMode"
    static let autoPasteEnabled = "autoPasteEnabled"
    static let restoreClipboardAfterPaste = "restoreClipboardAfterPaste"
    static let pauseMediaDuringTranscription = "pauseMediaDuringTranscription"
    static let voiceCommandsEnabled = "voiceCommandsEnabled"
    static let voiceCommands = "voiceCommands"
    static let transcriptionGlossaryEnabled = "transcriptionGlossaryEnabled"
    static let transcriptionGlossary = "transcriptionGlossary"
    static let transcriptionScreenContextEnabled = "transcriptionScreenContextEnabled"
    static let transcriptionScreenContextOCREnabled = "transcriptionScreenContextOCREnabled"
    static let transcriptionLanguageID = "transcriptionLanguageID"
    static let enableDetailedLogging = "enableDetailedLogging"
    static let hasCompletedOnboarding = "hasCompletedOnboarding"
    static let keepDictationHistoryLocally = "keepDictationHistoryLocally"
  }

  // MARK: - Model

  var selectedModel: SpeechModel {
    get {
      let storedValue = defaults.string(forKey: Keys.selectedModel) ?? ""
      return SpeechModel(rawValue: storedValue) ?? ModelManager.defaultModel
    }
    set {
      defaults.set(newValue.rawValue, forKey: Keys.selectedModel)
    }
  }

  /// Reset a persisted non-Qwen selection to a downloaded Qwen model or the current default.
  func migrateSelectedModelToUserFacingIfNeeded() {
    let storedValue = defaults.string(forKey: Keys.selectedModel) ?? ""
    guard let model = SpeechModel(rawValue: storedValue), !model.isUserFacing else {
      return
    }

    ModelManager.shared.loadDownloadedModels()
    let replacement =
      SpeechModel.userFacingModels.first(where: { ModelManager.shared.isDownloaded($0) })
      ?? ModelManager.defaultModel
    defaults.set(replacement.rawValue, forKey: Keys.selectedModel)
  }

  var lastSeenDefaultModel: String? {
    get { defaults.string(forKey: Keys.lastSeenDefaultModel) }
    set { defaults.set(newValue, forKey: Keys.lastSeenDefaultModel) }
  }

  var lastAppliedDefaultModel: String? {
    get { defaults.string(forKey: Keys.lastAppliedDefaultModel) }
    set { defaults.set(newValue, forKey: Keys.lastAppliedDefaultModel) }
  }

  // MARK: - App Behavior

  var launchAtLogin: Bool {
    get { defaults.bool(forKey: Keys.launchAtLogin) }
    set {
      defaults.set(newValue, forKey: Keys.launchAtLogin)
      configureLaunchAtLogin(enabled: newValue)
    }
  }

  var showDockIcon: Bool {
    get { defaults.bool(forKey: Keys.showDockIcon) }
    set { defaults.set(newValue, forKey: Keys.showDockIcon) }
  }

  var recordingMode: RecordingMode {
    get {
      let rawValue = defaults.string(forKey: Keys.recordingMode) ?? RecordingMode.manual.rawValue
      return RecordingMode(rawValue: rawValue) ?? .manual
    }
    set { defaults.set(newValue.rawValue, forKey: Keys.recordingMode) }
  }

  /// When enabled, Voicey attempts to auto-paste the transcription into the active app.
  /// Requires Accessibility permission.
  var autoPasteEnabled: Bool {
    get { defaults.bool(forKey: Keys.autoPasteEnabled) }
    set { defaults.set(newValue, forKey: Keys.autoPasteEnabled) }
  }

  /// Whether to restore original clipboard after auto-paste.
  /// When enabled, the user's clipboard is preserved after transcription is pasted.
  var restoreClipboardAfterPaste: Bool {
    get { defaults.bool(forKey: Keys.restoreClipboardAfterPaste) }
    set { defaults.set(newValue, forKey: Keys.restoreClipboardAfterPaste) }
  }

  /// Whether to pause system media playback while Voicey is recording/transcribing.
  var pauseMediaDuringTranscription: Bool {
    get { defaults.bool(forKey: Keys.pauseMediaDuringTranscription) }
    set { defaults.set(newValue, forKey: Keys.pauseMediaDuringTranscription) }
  }

  func configureLaunchAtLogin(enabled: Bool) {
    do {
      if enabled {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
    } catch {
      AppLogger.general.error("Failed to configure launch at login: \(error)")
    }
  }

  // MARK: - Transcription Glossary (Qwen)

  /// When enabled, glossary terms are passed to Qwen3 ASR as decoder context before transcription.
  var transcriptionGlossaryEnabled: Bool {
    get { defaults.bool(forKey: Keys.transcriptionGlossaryEnabled) }
    set { defaults.set(newValue, forKey: Keys.transcriptionGlossaryEnabled) }
  }

  /// Comma- or newline-separated terms and names to bias Qwen transcription spelling.
  var transcriptionGlossary: String {
    get { defaults.string(forKey: Keys.transcriptionGlossary) ?? "" }
    set { defaults.set(newValue, forKey: Keys.transcriptionGlossary) }
  }

  /// When enabled, reads the target app's accessibility tree at record start and steers Qwen spelling.
  var transcriptionScreenContextEnabled: Bool {
    get { defaults.bool(forKey: Keys.transcriptionScreenContextEnabled) }
    set { defaults.set(newValue, forKey: Keys.transcriptionScreenContextEnabled) }
  }

  /// When enabled with screen context, uses on-device OCR on the target window if accessibility text is limited.
  var transcriptionScreenContextOCREnabled: Bool {
    get { defaults.bool(forKey: Keys.transcriptionScreenContextOCREnabled) }
    set { defaults.set(newValue, forKey: Keys.transcriptionScreenContextOCREnabled) }
  }

  /// Qwen3-ASR spoken-language hint (`language` parameter). `auto` lets the model detect language.
  var transcriptionLanguageID: String {
    get {
      let raw = defaults.string(forKey: Keys.transcriptionLanguageID)
        ?? TranscriptionQwenLanguage.autoOption.id
      return TranscriptionQwenLanguage.normalizedStoredID(raw)
    }
    set {
      defaults.set(
        TranscriptionQwenLanguage.normalizedStoredID(newValue),
        forKey: Keys.transcriptionLanguageID
      )
    }
  }

  // MARK: - Voice Commands

  var voiceCommandsEnabled: Bool {
    get { defaults.bool(forKey: Keys.voiceCommandsEnabled) }
    set { defaults.set(newValue, forKey: Keys.voiceCommandsEnabled) }
  }

  var voiceCommands: [VoiceCommand] {
    get {
      guard let data = defaults.data(forKey: Keys.voiceCommands),
        let commands = try? JSONDecoder().decode([VoiceCommand].self, from: data)
      else {
        return VoiceCommand.defaults
      }
      return commands
    }
    set {
      if let data = try? JSONEncoder().encode(newValue) {
        defaults.set(data, forKey: Keys.voiceCommands)
      }
    }
  }

  // MARK: - Debugging

  var enableDetailedLogging: Bool {
    get { defaults.bool(forKey: Keys.enableDetailedLogging) }
    set { defaults.set(newValue, forKey: Keys.enableDetailedLogging) }
  }

  /// When enabled, every utterance is stored under Application Support for local review.
  var keepDictationHistoryLocally: Bool {
    get { defaults.bool(forKey: Keys.keepDictationHistoryLocally) }
    set { defaults.set(newValue, forKey: Keys.keepDictationHistoryLocally) }
  }

  // MARK: - Onboarding

  var hasCompletedOnboarding: Bool {
    get { defaults.bool(forKey: Keys.hasCompletedOnboarding) }
    set { defaults.set(newValue, forKey: Keys.hasCompletedOnboarding) }
  }

  // MARK: - Reset

  func resetToDefaults() {
    if Bundle.main.bundleIdentifier != nil {
      if let bundleIdentifier = Bundle.main.bundleIdentifier {
        defaults.removePersistentDomain(forName: bundleIdentifier)
      }
    } else {
      defaults.removePersistentDomain(forName: Self.fallbackSuiteName)
    }
    defaults.synchronize()
    registerDefaults()
  }
}

extension Notification.Name {
  static let voiceySelectedModelDidChange = Notification.Name("voiceySelectedModelDidChange")
}
