import AVFoundation
import AppKit
import Foundation
import os

/// Manages system permissions required by the app
final class PermissionsManager: PermissionsProviding {
  static let shared = PermissionsManager()

  // Cache the key string to avoid multiple takeRetainedValue calls
  private static let accessibilityPromptKey: String =
    kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String

  private init() {}

  // MARK: - Microphone Permission

  /// Check current microphone permission status
  func checkMicrophonePermission() async -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
      return true
    case .notDetermined:
      return false
    case .denied, .restricted:
      return false
    @unknown default:
      return false
    }
  }

  /// Request microphone permission
  @discardableResult
  func requestMicrophonePermission() async -> Bool {
    await withCheckedContinuation { continuation in
      AVCaptureDevice.requestAccess(for: .audio) { granted in
        continuation.resume(returning: granted)
      }
    }
  }

  // MARK: - Accessibility Permission

  /// Check if accessibility permission is granted
  /// Required for global hotkeys and simulating keyboard input
  func checkAccessibilityPermission() -> Bool {
    // Use the simpler check without options dictionary for more reliable detection
    let trusted = AXIsProcessTrusted()

    AppLogger.general.info(
      "Accessibility check: AXIsProcessTrusted() = \(trusted), Bundle: \(Bundle.main.bundleIdentifier ?? "unknown")"
    )

    return trusted
  }

  /// Try to verify accessibility by actually attempting an operation
  /// This is more reliable than AXIsProcessTrusted() which can cache
  func verifyAccessibilityWorks() -> Bool {
    // Try to create a CGEventSource - this requires accessibility permission
    let source = CGEventSource(stateID: .combinedSessionState)
    let works = source != nil
    AppLogger.general.info("Accessibility verify (CGEventSource): \(works)")
    return works
  }

  /// Prompt user to grant accessibility permission
  /// Opens System Settings to the Accessibility pane
  func promptForAccessibilityPermission() {
    AppLogger.general.info("Opening System Settings for accessibility permission")
    // Just open System Settings - the AXIsProcessTrustedWithOptions prompt is unreliable
    // and can cause double dialogs
    openAccessibilitySettings()
  }

  /// Open System Settings to Accessibility pane
  func openAccessibilitySettings() {
    // Use the newer URL format for macOS 13+
    if let url = URL(
      string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    {
      NSWorkspace.shared.open(url)
    }
  }

  // MARK: - Helper Methods

  /// Open System Settings to Microphone pane
  func openMicrophoneSettings() {
    if let url = URL(
      string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    {
      NSWorkspace.shared.open(url)
    }
  }

  /// Check all required permissions
  func checkAllPermissions() async -> PermissionStatus {
    let microphone = await checkMicrophonePermission()
    let accessibility = checkAccessibilityPermission()

    return PermissionStatus(
      microphone: microphone,
      accessibility: accessibility
    )
  }

  /// Force a fresh check of accessibility permission using multiple methods
  func refreshAccessibilityPermission() -> Bool {
    // Try multiple detection methods
    let axTrusted = AXIsProcessTrusted()
    let cgEventWorks = verifyAccessibilityWorks()

    AppLogger.general.info(
      "Refresh accessibility: AXIsProcessTrusted=\(axTrusted), CGEventSource=\(cgEventWorks)")

    // Return true if either method indicates we have permission
    return axTrusted || cgEventWorks
  }
}

struct PermissionStatus {
  let microphone: Bool
  let accessibility: Bool

  var allGranted: Bool {
    microphone && accessibility
  }

  var missing: [String] {
    var result: [String] = []
    if !microphone { result.append("Microphone") }
    if !accessibility { result.append("Accessibility") }
    return result
  }
}
