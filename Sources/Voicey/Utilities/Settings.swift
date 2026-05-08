import Foundation
import ServiceManagement
import VoiceyCore
import os

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
      Keys.autoPasteEnabled: false,  // Disabled by default - advanced feature requiring Accessibility
      Keys.restoreClipboardAfterPaste: true,  // Restore original clipboard after paste
      Keys.voiceCommandsEnabled: false,
      Keys.enableDetailedLogging: false,
      Keys.hasCompletedOnboarding: false
    ])
  }

  // MARK: - Keys

  private enum Keys {
    static let selectedModel = "selectedModel"
    static let lastSeenDefaultModel = "lastSeenDefaultModel"
    static let lastAppliedDefaultModel = "lastAppliedDefaultModel"
    static let launchAtLogin = "launchAtLogin"
    static let showDockIcon = "showDockIcon"
    static let autoPasteEnabled = "autoPasteEnabled"
    static let restoreClipboardAfterPaste = "restoreClipboardAfterPaste"
    static let voiceCommandsEnabled = "voiceCommandsEnabled"
    static let voiceCommands = "voiceCommands"
    static let enableDetailedLogging = "enableDetailedLogging"
    static let hasCompletedOnboarding = "hasCompletedOnboarding"
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
