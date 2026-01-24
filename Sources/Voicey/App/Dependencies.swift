import Foundation

// MARK: - Service Protocols

/// Protocol for settings management
protocol SettingsProviding {
  var selectedModel: WhisperModel { get set }
  var launchAtLogin: Bool { get set }
  var showDockIcon: Bool { get }
  var autoPasteEnabled: Bool { get set }
  var restoreClipboardAfterPaste: Bool { get set }
  var voiceCommandsEnabled: Bool { get set }
  var voiceCommands: [VoiceCommand] { get set }
  var enableDetailedLogging: Bool { get set }

  func configureLaunchAtLogin(enabled: Bool)
  func resetToDefaults()
}

/// Protocol for model management
protocol ModelProviding: ObservableObject {
  var downloadedModels: Set<WhisperModel> { get }
  var isDownloading: [WhisperModel: Bool] { get }
  var downloadError: String? { get }
  var hasDownloadedModel: Bool { get }
  var modelsDirectory: URL { get }

  func loadDownloadedModels()
  func isDownloaded(_ model: WhisperModel) -> Bool
  func downloadModel(_ model: WhisperModel)
  func cancelDownload(_ model: WhisperModel)
  func deleteModel(_ model: WhisperModel) throws
}

/// Protocol for permissions management
protocol PermissionsProviding {
  func checkMicrophonePermission() async -> Bool
  func requestMicrophonePermission() async -> Bool
  func checkAccessibilityPermission() -> Bool
  func promptForAccessibilityPermission()
  func openAccessibilitySettings()
  func openMicrophoneSettings()
}

/// Protocol for notifications
protocol NotificationProviding {
  func showMicrophoneRequiredNotification()
  func showNoModelNotification()
  func showModelDownloadComplete(model: WhisperModel)
  func showModelDownloadFailed(reason: String)
  func showModelUpgradeComplete(model: WhisperModel)
  func showModelLoading()
  func showTranscriptionCopied()
  func showTranscriptionError(_ message: String)
  func showNetworkError()
  func showPerformanceWarning(_ message: String)
}

// MARK: - Dependencies Container

/// Container for all injectable dependencies
/// Use `Dependencies.shared` for production, or create custom instances for testing
final class Dependencies {
  static let shared = Dependencies()

  let settings: SettingsProviding
  let permissions: PermissionsProviding
  let notifications: NotificationProviding

  /// Production initializer using real implementations
  private init() {
    self.settings = SettingsManager.shared
    self.permissions = PermissionsManager.shared
    self.notifications = NotificationManager.shared
  }

  /// Testing initializer allowing mock implementations
  init(
    settings: SettingsProviding,
    permissions: PermissionsProviding,
    notifications: NotificationProviding
  ) {
    self.settings = settings
    self.permissions = permissions
    self.notifications = notifications
  }
}
