import Foundation
import UserNotifications
import AppKit
import os

/// Manages system notifications for the app
final class NotificationManager: NotificationProviding {
    static let shared = NotificationManager()
    
    private init() {
        requestNotificationPermission()
    }
    
    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
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
    
    func showAccessibilityRequiredNotification() {
        showNotification(
            title: "Accessibility Access Required",
            body: "Voicey needs accessibility access. Click the Voicey menu and select Settings."
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
            body: "\(model.displayName) is ready to use. Press Ctrl+C to start transcribing."
        )
    }
    
    func showModelDownloadFailed(reason: String) {
        showNotification(
            title: "Download Failed",
            body: reason
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
