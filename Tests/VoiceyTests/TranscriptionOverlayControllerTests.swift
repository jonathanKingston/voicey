import AppKit
import XCTest
@testable import Voicey

@MainActor
final class TranscriptionOverlayControllerTests: XCTestCase {
  private let overlayScreenshotPathEnvironmentKey = "VOICEY_OVERLAY_SCREENSHOT_PATH"

  override func setUp() {
    super.setUp()
    _ = NSApplication.shared.setActivationPolicy(.accessory)
  }

  override func tearDown() {
    closeWindows()
    super.tearDown()
  }

  func testShowKeepsPanelAsFirstResponder() {
    let appState = AppState()
    appState.transcriptionState = .recording(startTime: Date())
    appState.audioLevel = 0.4

    XCTAssertEqual(L10n.State.listening, "Listening...")

    let controller = TranscriptionOverlayController(appState: appState)

    controller.show()
    pumpRunLoop()

    guard let keyWindow = NSApplication.shared.keyWindow else {
      XCTFail("Expected overlay panel to become the key window")
      return
    }

    XCTAssertTrue(keyWindow is KeyablePanel)
    XCTAssertTrue(
      keyWindow.firstResponder === keyWindow,
      "Expected overlay panel to keep first responder so the cancel button does not receive initial focus"
    )

    if let screenshotPath = ProcessInfo.processInfo.environment[overlayScreenshotPathEnvironmentKey] {
      try? saveScreenshot(of: keyWindow, to: screenshotPath)
    }
  }

  private func pumpRunLoop() {
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
  }

  private func closeWindows() {
    for window in NSApplication.shared.windows {
      window.orderOut(nil)
      window.close()
    }
    pumpRunLoop()
  }

  private func saveScreenshot(of window: NSWindow, to path: String) throws {
    let contentView = try XCTUnwrap(window.contentView)
    contentView.layoutSubtreeIfNeeded()
    contentView.displayIfNeeded()

    let bounds = contentView.bounds
    let bitmap = try XCTUnwrap(contentView.bitmapImageRepForCachingDisplay(in: bounds))
    contentView.cacheDisplay(in: bounds, to: bitmap)

    let pngData = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true,
      attributes: nil
    )
    try pngData.write(to: url)
  }
}
