import Foundation

/// Localization utility for accessing translated strings
/// Falls back to English if the user's language is not supported
///
/// Supported languages: English, Spanish, German, French, Japanese, Chinese (Simplified)
enum L10n {
    /// Supported language codes for reference
    static let supportedLanguages = ["en", "es", "de", "fr", "ja", "zh-Hans"]

    /// Get a localized string with optional arguments
    /// Uses Bundle.main which automatically selects the appropriate .lproj based on system language
    /// Falls back to English (development language) if the user's language is not supported
    /// - Parameters:
    ///   - key: The localization key
    ///   - args: Optional format arguments
    /// - Returns: The localized string, or the key if not found
    static func string(_ key: String, _ args: CVarArg...) -> String {
        let format = NSLocalizedString(key, tableName: "Localizable", bundle: Bundle.main, comment: "")
        if args.isEmpty {
            return format
        }
        return String(format: format, arguments: args)
    }

    // MARK: - App General

    enum App {
        static var name: String { L10n.string("app.name") }
        static var tagline: String { L10n.string("app.tagline") }
    }

    // MARK: - Transcription States

    enum State {
        static var ready: String { L10n.string("state.ready") }
        static var loadingModel: String { L10n.string("state.loadingModel") }
        static var listening: String { L10n.string("state.listening") }
        static var transcribing: String { L10n.string("state.transcribing") }
        static var done: String { L10n.string("state.done") }
        static func error(_ message: String) -> String { L10n.string("state.error", message) }
    }

    // MARK: - Model Status

    enum ModelStatus {
        static var noModel: String { L10n.string("modelStatus.noModel") }
        static var loading: String { L10n.string("modelStatus.loading") }
        static var ready: String { L10n.string("modelStatus.ready") }
        static func error(_ message: String) -> String { L10n.string("modelStatus.error", message) }
    }

    // MARK: - Menu Items

    enum Menu {
        static var startTranscription: String { L10n.string("menu.startTranscription") }
        static var stopTranscription: String { L10n.string("menu.stopTranscription") }
        static var settings: String { L10n.string("menu.settings") }
        static var checkForUpdates: String { L10n.string("menu.checkForUpdates") }
        static var about: String { L10n.string("menu.about") }
        static var quit: String { L10n.string("menu.quit") }
    }

    // MARK: - Tooltips

    enum Tooltip {
        static var noModelDownloaded: String { L10n.string("tooltip.noModelDownloaded") }
        static var loadingModel: String { L10n.string("tooltip.loadingModel") }
        static var ready: String { L10n.string("tooltip.ready") }
        static func error(_ message: String) -> String { L10n.string("tooltip.error", message) }
    }

    // MARK: - Settings Tabs

    enum Settings {
        static var setup: String { L10n.string("settings.setup") }
        static var general: String { L10n.string("settings.general") }
        static var hotkey: String { L10n.string("settings.hotkey") }
        static var audio: String { L10n.string("settings.audio") }
        static var model: String { L10n.string("settings.model") }
        static var voiceCommands: String { L10n.string("settings.voiceCommands") }
        static var advanced: String { L10n.string("settings.advanced") }
    }

    // MARK: - Setup View

    enum Setup {
        static var downloadModel: String { L10n.string("setup.downloadModel") }
        static func downloadModelDesc(_ modelName: String) -> String {
            L10n.string("setup.downloadModelDesc", modelName)
        }
        static var downloadQualityModel: String { L10n.string("setup.downloadQualityModel") }
        static func downloadQualityModelDesc(_ modelName: String) -> String {
            L10n.string("setup.downloadQualityModelDesc", modelName)
        }
        static var microphoneAccess: String { L10n.string("setup.microphoneAccess") }
        static var microphoneAccessDesc: String { L10n.string("setup.microphoneAccessDesc") }
        static var launchAtLogin: String { L10n.string("setup.launchAtLogin") }
        static var launchAtLoginDesc: String { L10n.string("setup.launchAtLoginDesc") }
        static var ready: String { L10n.string("setup.ready") }
        static var download: String { L10n.string("setup.download") }
        static var downloading: String { L10n.string("setup.downloading") }
        static var afterFastModel: String { L10n.string("setup.afterFastModel") }
        static var granted: String { L10n.string("setup.granted") }
        static var allow: String { L10n.string("setup.allow") }
        static var enabled: String { L10n.string("setup.enabled") }
        static var enable: String { L10n.string("setup.enable") }
        static var optional: String { L10n.string("setup.optional") }
        static var allSetQualityModel: String { L10n.string("setup.allSetQualityModel") }
        static var qualityModelDownloading: String { L10n.string("setup.qualityModelDownloading") }
        static var readyToUse: String { L10n.string("setup.readyToUse") }
        static func downloadingProgress(_ percent: Int) -> String {
            L10n.string("setup.downloadingProgress", percent)
        }
        static var modelDownloadRequired: String { L10n.string("setup.modelDownloadRequired") }
        static var microphoneRequired: String { L10n.string("setup.microphoneRequired") }
    }

    // MARK: - General Settings

    enum General {
        static var output: String { L10n.string("general.output") }
        static var outputDescription: String { L10n.string("general.outputDescription") }
        static var outputTip: String { L10n.string("general.outputTip") }
        static var launchAtLogin: String { L10n.string("general.launchAtLogin") }
        static var showDockIcon: String { L10n.string("general.showDockIcon") }
    }

    // MARK: - Hotkey Settings

    enum Hotkey {
        static var transcriptionHotkey: String { L10n.string("hotkey.transcriptionHotkey") }
        static var toggleRecording: String { L10n.string("hotkey.toggleRecording") }
        static var hotkeyDescription: String { L10n.string("hotkey.hotkeyDescription") }
        static var resetToDefault: String { L10n.string("hotkey.resetToDefault") }
        static var escapeKey: String { L10n.string("hotkey.escapeKey") }
        static var escapeDescription: String { L10n.string("hotkey.escapeDescription") }
    }

    // MARK: - Audio Settings

    enum Audio {
        static var inputDevice: String { L10n.string("audio.inputDevice") }
        static var microphone: String { L10n.string("audio.microphone") }
        static var systemDefault: String { L10n.string("audio.systemDefault") }
        static var inputDeviceDescription: String { L10n.string("audio.inputDeviceDescription") }
        static var testMicrophone: String { L10n.string("audio.testMicrophone") }
        static var testInput: String { L10n.string("audio.testInput") }
        static var testing: String { L10n.string("audio.testing") }
        static var testDescription: String { L10n.string("audio.testDescription") }
    }

    // MARK: - Model Settings

    enum Model {
        static var selectedModel: String { L10n.string("model.selectedModel") }
        static var modelLabel: String { L10n.string("model.modelLabel") }
        static var availableModels: String { L10n.string("model.availableModels") }
        static var performance: String { L10n.string("model.performance") }
        static var performanceDescription: String { L10n.string("model.performanceDescription") }
        static var recommended: String { L10n.string("model.recommended") }
        static var download: String { L10n.string("model.download") }
        static var delete: String { L10n.string("model.delete") }
        static var failedToDelete: String { L10n.string("model.failedToDelete") }
        static var ok: String { L10n.string("model.ok") }
        static var unknownError: String { L10n.string("model.unknownError") }
    }

    // MARK: - Voice Commands

    enum VoiceCommands {
        static var enable: String { L10n.string("voiceCommands.enable") }
        static var description: String { L10n.string("voiceCommands.description") }
        static var commands: String { L10n.string("voiceCommands.commands") }
        static var addCustomCommand: String { L10n.string("voiceCommands.addCustomCommand") }
        static var resetToDefaults: String { L10n.string("voiceCommands.resetToDefaults") }
        static var phrase: String { L10n.string("voiceCommands.phrase") }
        static var newLine: String { L10n.string("voiceCommands.newLine") }
        static var newParagraph: String { L10n.string("voiceCommands.newParagraph") }
        static var scratchThat: String { L10n.string("voiceCommands.scratchThat") }
        static func customText(_ text: String) -> String { L10n.string("voiceCommands.customText", text) }
        static var addVoiceCommand: String { L10n.string("voiceCommands.addVoiceCommand") }
        static var triggerPhrase: String { L10n.string("voiceCommands.triggerPhrase") }
        static var action: String { L10n.string("voiceCommands.action") }
        static var actionNewLine: String { L10n.string("voiceCommands.actionNewLine") }
        static var actionNewParagraph: String { L10n.string("voiceCommands.actionNewParagraph") }
        static var actionCustomText: String { L10n.string("voiceCommands.actionCustomText") }
        static var customTextLabel: String { L10n.string("voiceCommands.customTextLabel") }
        static var cancel: String { L10n.string("voiceCommands.cancel") }
        static var add: String { L10n.string("voiceCommands.add") }
    }

    // MARK: - Advanced Settings

    enum Advanced {
        static var autoInsert: String { L10n.string("advanced.autoInsert") }
        static var autoInsertToggle: String { L10n.string("advanced.autoInsertToggle") }
        static var autoInsertEnabledDesc: String { L10n.string("advanced.autoInsertEnabledDesc") }
        static var autoInsertDisabledDesc: String { L10n.string("advanced.autoInsertDisabledDesc") }
        static var restoreClipboard: String { L10n.string("advanced.restoreClipboard") }
        static var restoreClipboardDesc: String { L10n.string("advanced.restoreClipboardDesc") }
        static var accessibilityPermission: String { L10n.string("advanced.accessibilityPermission") }
        static var accessibilityGranted: String { L10n.string("advanced.accessibilityGranted") }
        static var openSettings: String { L10n.string("advanced.openSettings") }
        static var accessibilityRequired: String { L10n.string("advanced.accessibilityRequired") }
        static var debugging: String { L10n.string("advanced.debugging") }
        static var enableDetailedLogging: String { L10n.string("advanced.enableDetailedLogging") }
        static var loggingDescription: String { L10n.string("advanced.loggingDescription") }
        static var data: String { L10n.string("advanced.data") }
        static var clearAllData: String { L10n.string("advanced.clearAllData") }
        static var clearDataDescription: String { L10n.string("advanced.clearDataDescription") }
        static var failedToClear: String { L10n.string("advanced.failedToClear") }
        static var about: String { L10n.string("advanced.about") }
        static var version: String { L10n.string("advanced.version") }
        static var build: String { L10n.string("advanced.build") }
        static var distribution: String { L10n.string("advanced.distribution") }
        static var directInstall: String { L10n.string("advanced.directInstall") }
        static var appStore: String { L10n.string("advanced.appStore") }
        static var checkForUpdates: String { L10n.string("advanced.checkForUpdates") }
        static var updatesDeliveredFrom: String { L10n.string("advanced.updatesDeliveredFrom") }
    }

    // MARK: - Model Download Window

    enum Download {
        static var whisperModels: String { L10n.string("download.whisperModels") }
        static var description: String { L10n.string("download.description") }
        static var done: String { L10n.string("download.done") }
    }

    // MARK: - Overlay

    enum Overlay {
        static var cancelHelp: String { L10n.string("overlay.cancelHelp") }
    }

    // MARK: - Common

    enum Common {
        static var ok: String { L10n.string("common.ok") }
        static var cancel: String { L10n.string("common.cancel") }
        static var error: String { L10n.string("common.error") }
    }
}
