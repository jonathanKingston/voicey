import Foundation
import ServiceManagement
import os

/// Manages user settings and preferences
final class SettingsManager: SettingsProviding {
  static let shared = SettingsManager()

  /// Use a specific suite to ensure consistent storage regardless of how app is launched
  private let defaults: UserDefaults

  private init() {
    // Use explicit suite name so settings work consistently when running from
    // command line (.build/debug/Voicey) or as app bundle (Voicey.app)
    if let suite = UserDefaults(suiteName: "work.voicey.Voicey") {
      defaults = suite
    } else {
      defaults = UserDefaults.standard
    }
    registerDefaults()
  }

  private func registerDefaults() {
    defaults.register(defaults: [
      // Default to fast model - onboarding will upgrade to quality model in background
      Keys.selectedModel: WhisperModel.base.rawValue,
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

  var selectedModel: WhisperModel {
    get {
      let storedValue = defaults.string(forKey: Keys.selectedModel) ?? ""
      return WhisperModel(rawValue: storedValue) ?? .largeTurbo
    }
    set {
      defaults.set(newValue.rawValue, forKey: Keys.selectedModel)
    }
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
    let domain = Bundle.main.bundleIdentifier ?? "com.voicey"
    defaults.removePersistentDomain(forName: domain)
    defaults.synchronize()
    registerDefaults()
  }
}
