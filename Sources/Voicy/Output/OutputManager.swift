import Foundation
import AppKit

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
        
        // Try menuBarOwningApplication first (the app with menu bar focus)
        if let menuApp = workspace.menuBarOwningApplication,
           menuApp.bundleIdentifier != myBundleId {
            previousApp = menuApp
            log("Saved menu bar app: \(menuApp.localizedName ?? "unknown") (bundle: \(menuApp.bundleIdentifier ?? "?"))")
            return
        }
        
        // Fallback to frontmostApplication
        if let frontmost = workspace.frontmostApplication,
           frontmost.bundleIdentifier != myBundleId {
            previousApp = frontmost
            log("Saved frontmost app: \(frontmost.localizedName ?? "unknown") (bundle: \(frontmost.bundleIdentifier ?? "?"))")
            return
        }
        
        // Last resort: find any active app that isn't us
        for app in workspace.runningApplications {
            if app.isActive && app.bundleIdentifier != myBundleId {
                previousApp = app
                log("Saved active app: \(app.localizedName ?? "unknown") (bundle: \(app.bundleIdentifier ?? "?"))")
                return
            }
        }
        
        log("WARNING - Could not find previous app to save")
    }
    
    func deliver(text: String, completion: (() -> Void)? = nil) {
        let mode = SettingsManager.shared.outputMode
        
        log("Delivering text with mode: \(mode.rawValue)")
        log("Text: \"\(text)\"")
        
        // Always copy to clipboard first
        clipboardManager.copy(text)
        log("Copied to clipboard")
        
        // If we need to paste
        if mode == .pasteOnly || mode == .both {
            // Restore focus to previous app and paste
            if let app = previousApp {
                log("Will activate \(app.localizedName ?? "unknown")...")
                
                // Activate the app and wait for it to become active
                Task { @MainActor in
                    let activated = await activateAppAndWait(app, timeout: 2.0)
                    log("Activation result: \(activated)")
                    
                    keyboardSimulator.simulatePaste()
                    log("Paste command sent")
                    
                    // Small delay to let paste complete before calling completion
                    try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                    completion?()
                }
            } else {
                log("WARNING - No previous app saved, pasting to current focus")
                Task { @MainActor in
                    // Small delay to ensure we're ready
                    try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
                    keyboardSimulator.simulatePaste()
                    try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                    completion?()
                }
            }
        } else {
            // Clipboard only mode - complete immediately
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
    private func activateAppAndWait(_ app: NSRunningApplication, timeout: TimeInterval) async -> Bool {
        let _ = app.activate(options: .activateIgnoringOtherApps)
        
        let deadline = Date().addingTimeInterval(timeout)
        let pollInterval: UInt64 = 30_000_000 // 30ms
        
        while Date() < deadline {
            if app.isActive {
                // Give a tiny bit more time for the app to fully settle
                try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
                return true
            }
            try? await Task.sleep(nanoseconds: pollInterval)
        }
        
        log("WARNING - App did not become active within timeout")
        return false
    }
}
