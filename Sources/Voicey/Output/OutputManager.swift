import AppKit
import Foundation
import os

/// Serializes clipboard ownership, target activation, paste dispatch and restoration.
final class OutputManager: @unchecked Sendable {
  private let clipboardManager: ClipboardManager
  private let autoPaste: AutoPasteDelivering
  private let notifications: NotificationProviding
  private let settings: SettingsProviding
  private let permissions: PermissionsProviding
  @MainActor private var autoPasteTask: Task<Void, Never>?

  init(
    notifications: NotificationProviding = NotificationManager.shared,
    settings: SettingsProviding = SettingsManager.shared,
    permissions: PermissionsProviding = PermissionsManager.shared,
    clipboard: ClipboardManager = .shared,
    autoPaste: AutoPasteDelivering = SystemAutoPasteDelivery()
  ) {
    self.notifications = notifications
    self.settings = settings
    self.permissions = permissions
    self.clipboardManager = clipboard
    self.autoPaste = autoPaste
  }

  @discardableResult
  func deliver(
    text: String, targetPID: pid_t? = nil, completion: (@Sendable () -> Void)? = nil
  ) -> Task<Void, Never> {
    Task { @MainActor in
      let previousTask = self.autoPasteTask
      self.autoPasteTask = Task { @MainActor in
        if let previousTask { await previousTask.value }
        await self.performDelivery(text: text, targetPID: targetPID, completion: completion)
      }
      await self.autoPasteTask?.value
    }
  }

  @MainActor
  private func performDelivery(
    text: String, targetPID: pid_t?, completion: (@Sendable () -> Void)?
  ) async {
    guard text.rangeOfCharacter(from: .whitespacesAndNewlines.inverted) != nil else {
      AppLogger.output.warning("Deliver: skipping empty transcription")
      completion?()
      return
    }

    // Snapshot and copy inside the serialized transaction. Later dictations must not
    // overwrite this clipboard while the target is still consuming it.
    let autoPasteEnabled = settings.autoPasteEnabled
    let restoreEnabled = autoPasteEnabled && settings.restoreClipboardAfterPaste
    let savedClipboard = restoreEnabled ? clipboardManager.captureContents() : nil
    clipboardManager.copy(text)
    completion?() // Hide the recording overlay before restoring target activation.

    guard autoPasteEnabled else {
      notifications.showTranscriptionCopied()
      return
    }
    guard permissions.checkAccessibilityPermission() else {
      permissions.promptForAccessibilityPermission()
      notifications.showTranscriptionCopied()
      return
    }
    guard let targetPID, await autoPaste.activateTarget(pid: targetPID) else {
      AppLogger.output.warning("Auto-paste: target activation failed; transcription remains on clipboard")
      notifications.showTranscriptionCopied()
      return
    }

    // A user copy during activation takes precedence. Do not paste unrelated clipboard data.
    guard clipboardManager.currentText() == text else {
      AppLogger.output.warning("Auto-paste: clipboard changed during activation; nothing dispatched")
      return
    }
    let clipboardChangeCount = clipboardManager.changeCount
    let outcome = await autoPaste.paste(text, targetPID: targetPID)
    guard outcome == .confirmed else {
      AppLogger.output.warning(
        "Auto-paste: \(outcome.rawValue); retaining clipboard, no automatic retry"
      )
      notifications.showTranscriptionCopied()
      return
    }

    // Confirmation is an exact AX value/selection transition, not proof of renderer send state.
    // Leave time for the target to finish clipboard handling, then restore only our own copy.
    if let savedClipboard {
      do {
        try await Task.sleep(nanoseconds: 200_000_000)
      } catch {
        AppLogger.output.debug("Auto-paste: cancelled before clipboard restoration")
        return
      }
      guard clipboardManager.changeCount == clipboardChangeCount else {
        AppLogger.output.info("Auto-paste: skipping restoration because another app changed the clipboard")
        return
      }
      clipboardManager.restoreContents(savedClipboard)
    }
  }
}
