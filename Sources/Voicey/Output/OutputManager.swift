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
  func deliver(text: String, targetPID: pid_t? = nil, completion: (() -> Void)? = nil) {
    AppLogger.output.info("Deliver: TextLength=\(text.count)")
    AppLogger.output.debug("Deliver: Full text: \"\(text)\"")

    // Save original clipboard if user wants it restored after paste
    let shouldRestoreClipboard = settings.autoPasteEnabled && settings.restoreClipboardAfterPaste
    if shouldRestoreClipboard {
      clipboardManager.saveContents()
    }

    // Copy transcribed text to clipboard
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

    // Optional auto-paste (requires Accessibility - only available in direct distribution)
    #if VOICEY_DIRECT_DISTRIBUTION
    if settings.autoPasteEnabled {
      guard permissions.checkAccessibilityPermission() else {
        AppLogger.output.error("Auto-paste enabled but Accessibility permission is not granted")
        permissions.promptForAccessibilityPermission()
        clipboardManager.discardSavedContents()
        notifications.showTranscriptionCopied()
        completion?()
        return
      }

      AppLogger.output.info("Auto-paste enabled - attempting to insert text")
      debugPrint("🔌 Auto-paste: Starting insert flow, targetPID=\(targetPID?.description ?? "nil")", category: "OUTPUT")

      Task { @MainActor in
        // Let caller clean up UI first (hide overlay, etc.)
        completion?()

        // Activate target app and wait for focus
        await self.activateTargetApp(pid: targetPID)

        // Attempt to paste via accessibility
        let success = AccessibilityPaster.paste(text)

        if success {
          AppLogger.output.info("Deliver: Auto-paste succeeded")
          debugPrint("✅ Auto-paste: Successfully inserted via Accessibility API!", category: "OUTPUT")

          // Restore clipboard after a short delay (let paste complete)
          if shouldRestoreClipboard {
            try? await Task.sleep(nanoseconds: 200_000_000)  // 200ms
            self.clipboardManager.restoreContents()
          }
        } else {
          AppLogger.output.warning("Deliver: Auto-paste failed, text remains on clipboard")
          debugPrint("❌ Auto-paste: All methods failed - text remains on clipboard", category: "OUTPUT")
          self.clipboardManager.discardSavedContents()
          self.notifications.showTranscriptionCopied()
        }
      }
      return
    }
    #endif

    // Show notification that text is ready to paste
    notifications.showTranscriptionCopied()
    AppLogger.output.info("Deliver: Notification shown - user can now press ⌘V to paste")

    completion?()
  }

  /// Activate the target app and wait for it to become active
  private func activateTargetApp(pid: pid_t?) async {
    guard let pid = pid,
          let targetApp = NSRunningApplication(processIdentifier: pid),
          targetApp.bundleIdentifier != Bundle.main.bundleIdentifier
    else {
      debugPrint("⚠️ Auto-paste: No valid target app - pid=\(pid?.description ?? "nil")", category: "OUTPUT")
      AppLogger.output.warning("Auto-paste: No valid target app PID captured; pasting into current focus")
      return
    }

    debugPrint("🎯 Auto-paste: Activating target app '\(targetApp.localizedName ?? "unknown")' (pid: \(pid), bundle: \(targetApp.bundleIdentifier ?? "none"))", category: "OUTPUT")
    let activated = targetApp.activate(options: [.activateIgnoringOtherApps])
    debugPrint("🎯 Auto-paste: activate() returned \(activated)", category: "OUTPUT")

    // Wait for app to become active (up to 500ms)
    for attempt in 1...50 {
      if targetApp.isActive {
        debugPrint("✅ Auto-paste: Target app became active after \(attempt * 10)ms", category: "OUTPUT")
        break
      }
      try? await Task.sleep(nanoseconds: 10_000_000)  // 10ms
    }

    if !targetApp.isActive {
      debugPrint("⚠️ Auto-paste: Target app still not active after 500ms", category: "OUTPUT")
    }

    // Extra delay for focus to settle on the text field
    try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms more
  }
}
