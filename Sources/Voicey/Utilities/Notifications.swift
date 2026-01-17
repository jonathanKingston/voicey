import AppKit
import Foundation
import UserNotifications
import os

/// Manages system notifications for the app
final class NotificationManager: NotificationProviding {
  static let shared = NotificationManager()

  /// Whether notifications are available (requires proper app bundle)
  private let notificationsAvailable: Bool

  private init() {
    // UNUserNotificationCenter requires a proper app bundle
    // When running from .build/debug/, there's no bundle and it crashes
    notificationsAvailable = Bundle.main.bundleIdentifier != nil

    if notificationsAvailable {
      requestNotificationPermission()
    } else {
      AppLogger.general.warning("Notifications unavailable - running without app bundle")
    }
  }

  private func requestNotificationPermission() {
    guard notificationsAvailable else { return }
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) {
      granted, error in
      if let error = error {
        AppLogger.general.error("Notification permission error: \(error)")
      }
    }
  }

  // MARK: - Permission Notifications

  func showMicrophoneRequiredNotification() {
    showNotification(
      title: "Microphone Access Required",
      body: "Voicey needs microphone access to transcribe your voice."
    )
  }

  // MARK: - Model Notifications

  func showNoModelNotification() {
    showNotification(
      title: "No Transcription Model",
      body: "Download a Whisper model from the Voicey menu."
    )
  }

  func showModelDownloadComplete(model: WhisperModel) {
    showNotification(
      title: "Model Downloaded",
      body: "\(model.displayName) is ready to use. Press Ctrl+V to start transcribing."
    )
  }

  func showModelDownloadFailed(reason: String) {
    showNotification(
      title: "Download Failed",
      body: reason
    )
  }

  func showModelUpgradeComplete(model: WhisperModel) {
    showNotification(
      title: "Model Upgraded",
      body: "Now using \(model.displayName) for better accuracy."
    )
  }

  // MARK: - Performance Notifications

  func showPerformanceWarning(_ message: String) {
    showNotification(
      title: "Performance Notice",
      body: message
    )
  }

  // MARK: - Transcription Notifications

  func showTranscriptionCopied() {
    showNotification(
      title: "Transcription Copied",
      body: "Press ⌘V to paste your transcribed text."
    )
  }

  // MARK: - Error Notifications

  func showTranscriptionError(_ message: String) {
    showNotification(
      title: "Transcription Error",
      body: message
    )
  }

  func showNetworkError() {
    showNotification(
      title: "No Internet Connection",
      body: "Model download paused. Check your connection."
    )
  }

  // MARK: - Generic Notification

  private func showNotification(title: String, body: String) {
    guard notificationsAvailable else {
      // Log instead when running without bundle
      AppLogger.general.info("Notification: \(title) - \(body)")
      return
    }

    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.sound = .default

    let request = UNNotificationRequest(
      identifier: UUID().uuidString,
      content: content,
      trigger: nil
    )

    UNUserNotificationCenter.current().add(request)
  }
}
