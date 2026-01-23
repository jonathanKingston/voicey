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

    // Always copy to clipboard first as a safety net
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

      AppLogger.output.info("Auto-paste enabled - attempting to insert text")
      debugPrint("🔌 Auto-paste: Starting insert flow, targetPID=\(targetPID?.description ?? "nil")", category: "OUTPUT")
      
      Task { @MainActor in
        // Let caller clean up UI first (hide overlay, etc.)
        completion?()

        // Activate target app first
        if let pid = targetPID,
          let targetApp = NSRunningApplication(processIdentifier: pid),
          targetApp.bundleIdentifier != Bundle.main.bundleIdentifier
        {
          debugPrint("🎯 Auto-paste: Activating target app '\(targetApp.localizedName ?? "unknown")' (pid: \(pid), bundle: \(targetApp.bundleIdentifier ?? "none"))", category: "OUTPUT")
          let activated = targetApp.activate(options: [.activateIgnoringOtherApps])
          debugPrint("🎯 Auto-paste: activate() returned \(activated)", category: "OUTPUT")
          
          // Wait for app to become active (up to 500ms)
          for i in 1...5 {
            try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
            if targetApp.isActive {
              debugPrint("✅ Auto-paste: Target app became active after \(i * 100)ms", category: "OUTPUT")
              break
            }
          }
          
          if !targetApp.isActive {
            debugPrint("⚠️ Auto-paste: Target app still not active after 500ms", category: "OUTPUT")
          }
          
          // Extra delay for focus to settle on the text field
          try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms more
        } else {
          debugPrint("⚠️ Auto-paste: No valid target app - pid=\(targetPID?.description ?? "nil")", category: "OUTPUT")
          AppLogger.output.warning("Auto-paste: No valid target app PID captured; pasting into current focus")
        }

        // Try Accessibility API first
        if AccessibilityPaster.paste(text) {
          debugPrint("✅ Auto-paste: Successfully inserted via Accessibility API!", category: "OUTPUT")
          AppLogger.output.info("Auto-paste: Successfully inserted via Accessibility API")
          return
        }

        debugPrint("❌ Auto-paste: Accessibility API failed", category: "OUTPUT")
        
        #if VOICEY_DIRECT_DISTRIBUTION
        // Direct distribution: Try CGEvents as fallback (not sandboxed)
        debugPrint("🔄 Auto-paste: Falling back to CGEvents (direct distribution)", category: "OUTPUT")
        AppLogger.output.info("Auto-paste: Accessibility API failed, falling back to CGEvents")
        KeyboardSimulator.simulatePaste()
        #else
        // Sandboxed build - Accessibility API didn't work, user must paste manually
        debugPrint("📋 Auto-paste: Sandboxed build - showing 'copied' notification for manual paste", category: "OUTPUT")
        AppLogger.output.warning("Auto-paste: Accessibility API failed in sandboxed build, user must paste manually")
        self.notifications.showTranscriptionCopied()
        #endif
      }
      return
    }

    // Show notification that text is ready to paste
    notifications.showTranscriptionCopied()
    AppLogger.output.info("Deliver: Notification shown - user can now press ⌘V to paste")

    completion?()
  }
}
