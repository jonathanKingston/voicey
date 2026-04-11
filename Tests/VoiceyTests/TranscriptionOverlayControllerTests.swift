import AppKit
import XCTest
@testable import Voicey

@MainActor
final class TranscriptionOverlayControllerTests: XCTestCase {
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
}
