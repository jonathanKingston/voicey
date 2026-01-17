import AppKit
import Foundation
import os

/// Output mode for transcribed text
enum OutputMode: String, CaseIterable, Identifiable {
  case clipboardOnly = "clipboard"
  case pasteOnly = "paste"
  case both = "both"

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .clipboardOnly: return "Clipboard Only"
    case .pasteOnly: return "Paste Only"
    case .both: return "Both (Clipboard + Paste)"
    }
  }

  var description: String {
    switch self {
    case .clipboardOnly: return "Copy transcribed text to clipboard"
    case .pasteOnly: return "Paste directly into active text field"
    case .both: return "Copy to clipboard and paste into active field"
    }
  }
}

/// Manages delivering transcribed text to the user
final class OutputManager {
  private let clipboardManager = ClipboardManager.shared
  private let keyboardSimulator = KeyboardSimulator.shared

  /// The app that was frontmost before we started recording
  var previousApp: NSRunningApplication?

  /// Save the current frontmost app (call before showing overlay)
  func saveFrontmostApp() {
    // Get the frontmost app that isn't our own app
    let workspace = NSWorkspace.shared
    let myBundleId = Bundle.main.bundleIdentifier

    AppLogger.output.info("SaveApp: Looking for frontmost app (our bundle: \(myBundleId ?? "?"))")

    // Try menuBarOwningApplication first (the app with menu bar focus)
    if let menuApp = workspace.menuBarOwningApplication,
      menuApp.bundleIdentifier != myBundleId
    {
      previousApp = menuApp
      AppLogger.output.info(
        "SaveApp: Saved menu bar app: \(menuApp.localizedName ?? "unknown") (bundle: \(menuApp.bundleIdentifier ?? "?"))"
      )
      return
    }

    // Fallback to frontmostApplication
    if let frontmost = workspace.frontmostApplication,
      frontmost.bundleIdentifier != myBundleId
    {
      previousApp = frontmost
      AppLogger.output.info(
        "SaveApp: Saved frontmost app: \(frontmost.localizedName ?? "unknown") (bundle: \(frontmost.bundleIdentifier ?? "?"))"
      )
      return
    }

    // Last resort: find any active app that isn't us
    for app in workspace.runningApplications {
      if app.isActive && app.bundleIdentifier != myBundleId {
        previousApp = app
        AppLogger.output.info(
          "SaveApp: Saved active app: \(app.localizedName ?? "unknown") (bundle: \(app.bundleIdentifier ?? "?"))"
        )
        return
      }
    }

    AppLogger.output.warning("SaveApp: Could not find previous app to save - paste may fail")
  }

  func deliver(text: String, completion: (() -> Void)? = nil) {
    let mode = SettingsManager.shared.outputMode

    AppLogger.output.info("Deliver: Mode=\(mode.rawValue), TextLength=\(text.count)")
    AppLogger.output.debug("Deliver: Full text: \"\(text)\"")

    // Always copy to clipboard first
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

    // If we need to paste
    if mode == .pasteOnly || mode == .both {
      // Restore focus to previous app and paste
      if let app = previousApp {
        AppLogger.output.info(
          "Deliver: Will activate '\(app.localizedName ?? "unknown")' (bundle: \(app.bundleIdentifier ?? "?"), pid: \(app.processIdentifier))"
        )
        AppLogger.output.info(
          "Deliver: App state - isActive: \(app.isActive), isTerminated: \(app.isTerminated), isHidden: \(app.isHidden)"
        )

        // Activate the app and wait for it to become active
        Task { @MainActor in
          let activated = await activateAppAndWait(app, timeout: 2.0)

          if activated {
            AppLogger.output.info("Deliver: App activated successfully, sending paste command...")
          } else {
            AppLogger.output.warning(
              "Deliver: App activation timed out, attempting paste anyway...")
          }

          keyboardSimulator.simulatePaste()

          // Small delay to let paste complete before calling completion
          try? await Task.sleep(nanoseconds: 150_000_000)  // 150ms
          AppLogger.output.info("Deliver: Paste sequence complete")
          completion?()
        }
      } else {
        AppLogger.output.warning("Deliver: No previous app saved, pasting to current focus")
        Task { @MainActor in
          // Small delay to ensure we're ready
          try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms
          keyboardSimulator.simulatePaste()
          try? await Task.sleep(nanoseconds: 150_000_000)  // 150ms
          completion?()
        }
      }
    } else {
      AppLogger.output.info("Deliver: Clipboard-only mode, skipping paste")
      completion?()
    }

    // Clear the saved app
    previousApp = nil
  }

  /// Activates an app and waits for it to become active
  /// - Parameters:
  ///   - app: The app to activate
  ///   - timeout: Maximum time to wait in seconds
  /// - Returns: true if the app became active within the timeout
  private func activateAppAndWait(_ app: NSRunningApplication, timeout: TimeInterval) async -> Bool
  {
    AppLogger.output.info(
      "Activate: Sending activate request to '\(app.localizedName ?? "unknown")'")

    let activateResult = app.activate(options: .activateIgnoringOtherApps)
    AppLogger.output.info("Activate: activate() returned \(activateResult)")

    let deadline = Date().addingTimeInterval(timeout)
    let pollInterval: UInt64 = 30_000_000  // 30ms
    var pollCount = 0

    while Date() < deadline {
      pollCount += 1
      if app.isActive {
        AppLogger.output.info(
          "Activate: App became active after \(pollCount) polls (~\(pollCount * 30)ms)")
        // Give a tiny bit more time for the app to fully settle
        try? await Task.sleep(nanoseconds: 80_000_000)  // 80ms settle time

        // Double-check it's still active
        let currentFront = NSWorkspace.shared.frontmostApplication
        AppLogger.output.info(
          "Activate: After settle, frontmost is: '\(currentFront?.localizedName ?? "none")'")

        return true
      }
      try? await Task.sleep(nanoseconds: pollInterval)
    }

    let currentFront = NSWorkspace.shared.frontmostApplication
    AppLogger.output.warning(
      "Activate: Timeout after \(pollCount) polls. Current frontmost: '\(currentFront?.localizedName ?? "none")'"
    )
    return false
  }
}
