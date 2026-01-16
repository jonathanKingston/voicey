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
        if let suite = UserDefaults(suiteName: "com.voicey.app") {
            defaults = suite
        } else {
            defaults = UserDefaults.standard
        }
        registerDefaults()
    }
    
    private func registerDefaults() {
        defaults.register(defaults: [
            Keys.outputMode: OutputMode.both.rawValue,
            Keys.selectedModel: WhisperModel.largeTurbo.rawValue,
            Keys.useGPUAcceleration: true,
            Keys.launchAtLogin: false,
            Keys.showDockIcon: false,
            Keys.voiceCommandsEnabled: false,
            Keys.enableDetailedLogging: false,
            Keys.hasCompletedOnboarding: false
        ])
    }
    
    // MARK: - Keys
    
    private enum Keys {
        static let outputMode = "outputMode"
        static let selectedModel = "selectedModel"
        static let useGPUAcceleration = "useGPUAcceleration"
        static let launchAtLogin = "launchAtLogin"
        static let showDockIcon = "showDockIcon"
        static let voiceCommandsEnabled = "voiceCommandsEnabled"
        static let voiceCommands = "voiceCommands"
        static let selectedInputDevice = "selectedInputDevice"
        static let enableDetailedLogging = "enableDetailedLogging"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
    }
    
    // MARK: - Output
    
    var outputMode: OutputMode {
        get {
            OutputMode(rawValue: defaults.string(forKey: Keys.outputMode) ?? "") ?? .both
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.outputMode)
        }
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
    
    var useGPUAcceleration: Bool {
        get { defaults.bool(forKey: Keys.useGPUAcceleration) }
        set { defaults.set(newValue, forKey: Keys.useGPUAcceleration) }
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
                  let commands = try? JSONDecoder().decode([VoiceCommand].self, from: data) else {
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
    
    // MARK: - Audio
    
    var selectedInputDevice: String? {
        get { defaults.string(forKey: Keys.selectedInputDevice) }
        set { defaults.set(newValue, forKey: Keys.selectedInputDevice) }
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
