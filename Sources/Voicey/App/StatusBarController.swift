import AppKit
import Combine
import SwiftUI

final class StatusBarController {
  private var statusItem: NSStatusItem
  private var menu: NSMenu
  private weak var appState: AppState?
  private weak var delegate: AppDelegate?
  private var animationTimer: Timer?
  private var cancellables = Set<AnyCancellable>()

  init(appState: AppState, delegate: AppDelegate) {
    self.appState = appState
    self.delegate = delegate

    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    menu = NSMenu()

    setupStatusItem()
    setupMenu()
    observeModelStatus()
  }

  private func setupStatusItem() {
    if let button = statusItem.button {
      let image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Voicey")
      image?.isTemplate = true
      button.image = image
      button.toolTip = "Voicey - Loading..."
    }
    statusItem.menu = menu
  }

  private func observeModelStatus() {
    appState?.$modelStatus
      .receive(on: DispatchQueue.main)
      .sink { [weak self] status in
        self?.updateTooltip(for: status)
        self?.updateIconForModelStatus(status)
      }
      .store(in: &cancellables)
  }

  private func updateTooltip(for status: ModelStatus) {
    guard let button = statusItem.button else { return }

    switch status {
    case .notDownloaded:
      button.toolTip = "Voicey - No model downloaded\nClick to download a model"
    case .loading:
      button.toolTip = "Voicey - Loading model...\nPlease wait before recording"
    case .ready:
      button.toolTip = "Voicey - Ready\nPress Ctrl+V to start recording"
    case .failed(let error):
      button.toolTip = "Voicey - Error: \(error)"
    }
  }

  private func updateIconForModelStatus(_ status: ModelStatus) {
    // Don't update icon if we're recording
    if appState?.isRecording == true { return }

    guard let button = statusItem.button else { return }

    switch status {
    case .loading:
      // Show loading indicator - dim the icon
      let image = NSImage(
        systemSymbolName: "mic.fill", accessibilityDescription: "Voicey - Loading")
      image?.isTemplate = true
      button.image = image
      button.alphaValue = 0.5
    case .ready:
      // Normal icon
      let image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Voicey - Ready")
      image?.isTemplate = true
      button.image = image
      button.alphaValue = 1.0
    case .notDownloaded, .failed:
      // Warning state
      let image = NSImage(
        systemSymbolName: "mic.slash", accessibilityDescription: "Voicey - Not Ready")
      image?.isTemplate = true
      button.image = image
      button.alphaValue = 1.0
    }
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
      title: "About Voicey",
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
      let image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Voicey")
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
