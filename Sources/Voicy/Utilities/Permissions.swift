import Foundation
import AVFoundation
import AppKit

/// Manages system permissions required by the app
final class PermissionsManager: PermissionsProviding {
    static let shared = PermissionsManager()
    
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
        // This checks if the app has accessibility permission
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: false]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }
    
    /// Prompt user to grant accessibility permission
    func promptForAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }
    
    /// Open System Settings to Accessibility pane
    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
    
    // MARK: - Helper Methods
    
    /// Open System Settings to Microphone pane
    func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
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
