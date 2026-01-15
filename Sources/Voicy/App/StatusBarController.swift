import AppKit
import SwiftUI

final class StatusBarController {
    private var statusItem: NSStatusItem
    private var menu: NSMenu
    private weak var appState: AppState?
    private weak var delegate: AppDelegate?
    private var animationTimer: Timer?
    
    init(appState: AppState, delegate: AppDelegate) {
        self.appState = appState
        self.delegate = delegate
        
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu = NSMenu()
        
        setupStatusItem()
        setupMenu()
    }
    
    private func setupStatusItem() {
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Voicy")
            image?.isTemplate = true
            button.image = image
        }
        statusItem.menu = menu
    }
    
    private func setupMenu() {
        let startItem = NSMenuItem(
            title: "Start Transcription",
            action: #selector(toggleTranscription),
            keyEquivalent: ""
        )
        startItem.target = self
        startItem.keyEquivalentModifierMask = .control
        startItem.keyEquivalent = "v"
        menu.addItem(startItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let settingsItem = NSMenuItem(
            title: "Settings...",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)
        
        let modelsItem = NSMenuItem(
            title: "Download Models...",
            action: #selector(openModelDownloader),
            keyEquivalent: ""
        )
        modelsItem.target = self
        menu.addItem(modelsItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let aboutItem = NSMenuItem(
            title: "About Voicy",
            action: #selector(showAbout),
            keyEquivalent: ""
        )
        aboutItem.target = self
        menu.addItem(aboutItem)
        
        let quitItem = NSMenuItem(
            title: "Quit",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)
    }
    
    func updateIcon(recording: Bool) {
        if recording {
            startRecordingAnimation()
        } else {
            stopRecordingAnimation()
        }
        
        // Update menu item title
        if let startItem = menu.items.first {
            startItem.title = recording ? "Stop Transcription" : "Start Transcription"
        }
    }
    
    private func startRecordingAnimation() {
        // Set red mic icon immediately
        if let button = statusItem.button {
            let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
            let image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Recording")
            button.image = image?.withSymbolConfiguration(config)
            button.image?.isTemplate = false
            button.contentTintColor = .systemRed
        }
        
        // Pulse animation
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let button = self?.statusItem.button else { return }
            if button.contentTintColor == .systemRed {
                button.contentTintColor = .systemOrange
            } else {
                button.contentTintColor = .systemRed
            }
        }
    }
    
    private func stopRecordingAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
        
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Voicy")
            image?.isTemplate = true
            button.image = image
            button.contentTintColor = nil
        }
    }
    
    // MARK: - Actions
    
    @objc private func toggleTranscription() {
        delegate?.toggleTranscription()
    }
    
    @objc private func openSettings() {
        delegate?.openSettings()
    }
    
    @objc private func openModelDownloader() {
        delegate?.openModelDownloader()
    }
    
    @objc private func showAbout() {
        delegate?.showAbout()
    }
    
    @objc private func quit() {
        delegate?.quit()
    }
}
