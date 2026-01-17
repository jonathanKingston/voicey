import AppKit
import Foundation
import os

/// Manages delivering transcribed text to the user via clipboard
final class OutputManager {
  private let clipboardManager = ClipboardManager.shared
  private let notifications: NotificationProviding
  private let settings: SettingsProviding
  private let permissions: PermissionsProviding

  init(
    notifications: NotificationProviding = NotificationManager.shared,
    settings: SettingsProviding = SettingsManager.shared,
    permissions: PermissionsProviding = PermissionsManager.shared
  ) {
    self.notifications = notifications
    self.settings = settings
    self.permissions = permissions
  }

  /// Deliver transcribed text by copying to clipboard and showing notification
  func deliver(text: String, completion: (() -> Void)? = nil) {
    AppLogger.output.info("Deliver: TextLength=\(text.count)")
    AppLogger.output.debug("Deliver: Full text: \"\(text)\"")

    // Copy to clipboard
    clipboardManager.copy(text)
    AppLogger.output.info("Deliver: Text copied to clipboard")

    // Verify clipboard
    if let clipboardText = clipboardManager.currentText() {
      if clipboardText == text {
        AppLogger.output.info("Deliver: Clipboard verified - text matches")
      } else {
        AppLogger.output.warning(
          "Deliver: Clipboard mismatch! Expected \(text.count) chars, got \(clipboardText.count)")
      }
    } else {
      AppLogger.output.error("Deliver: Clipboard is empty after copy!")
    }

    // Optional auto-paste (requires Accessibility)
    if settings.autoPasteEnabled {
      guard permissions.checkAccessibilityPermission() else {
        AppLogger.output.error("Auto-paste enabled but Accessibility permission is not granted")
        permissions.promptForAccessibilityPermission()
        notifications.showTranscriptionCopied()
        completion?()
        return
      }

      AppLogger.output.info("Auto-paste enabled - simulating ⌘V")
      KeyboardSimulator.simulatePaste()
      completion?()
      return
    }

    // Show notification that text is ready to paste
    notifications.showTranscriptionCopied()
    AppLogger.output.info("Deliver: Notification shown - user can now press ⌘V to paste")

    completion?()
  }
}
