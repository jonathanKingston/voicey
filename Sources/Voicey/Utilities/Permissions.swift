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
  func checkAccessibilityPermission() -> Bool {
    let trusted = AXIsProcessTrusted()
    let bundleId = Bundle.main.bundleIdentifier
    AppLogger.general.info("Accessibility check: AXIsProcessTrusted() = \(trusted), Bundle: \(bundleId ?? "none")")

    if bundleId == nil {
      AppLogger.general.warning(
        "Running without an app bundle identifier (.build/debug). Accessibility state may be unreliable; prefer running as a .app bundle."
      )
    }
    return trusted
  }

  /// Prompt user to grant accessibility permission (shows system prompt when possible)
  func promptForAccessibilityPermission() {
    if Bundle.main.bundleIdentifier == nil {
      AppLogger.general.warning(
        "Requesting Accessibility while running from .build/debug (no bundle id). Consider running as a .app bundle for a more reliable permission flow."
      )
    }

    let options: [String: Any] = [
      Self.accessibilityPromptKey: true
    ]

    _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    openAccessibilitySettings()
  }

  /// Open System Settings to Accessibility pane
  func openAccessibilitySettings() {
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
