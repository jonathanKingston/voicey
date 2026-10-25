import AppKit
import XCTest
import VoiceyCore
@testable import Voicey

final class OutputManagerTests: XCTestCase {
  @MainActor
  func testActivationFailureLeavesTranscriptionWithoutDispatchOrRestore() async {
    let fixture = OutputFixture()
    fixture.delivery.activationSucceeds = false
    await fixture.manager.deliver(text: "hello", targetPID: 42).value
    XCTAssertEqual(fixture.delivery.pastedTexts, [])
    XCTAssertEqual(fixture.clipboard.currentText(), "hello")
    fixture.pasteboard.releaseGlobally()
  }

  @MainActor
  func testMissingTargetLeavesTranscriptionWithoutActivation() async {
    let fixture = OutputFixture()
    await fixture.manager.deliver(text: "hello").value
    XCTAssertEqual(fixture.delivery.activationCount, 0)
    XCTAssertEqual(fixture.delivery.pastedTexts, [])
    XCTAssertEqual(fixture.clipboard.currentText(), "hello")
    fixture.pasteboard.releaseGlobally()
  }

  @MainActor
  func testAmbiguousDispatchRestoresClipboardWhenEnabled() async {
    let fixture = OutputFixture()
    fixture.delivery.outcome = .unconfirmed
    await fixture.manager.deliver(text: "hello", targetPID: 42).value
    XCTAssertEqual(fixture.delivery.pastedTexts, ["hello"])
    XCTAssertEqual(fixture.delivery.consumedClipboard, ["hello"])
    XCTAssertEqual(fixture.clipboard.currentText(), "original")
    fixture.pasteboard.releaseGlobally()
  }

  @MainActor
  func testAmbiguousDispatchKeepsTranscriptionWhenRestoreDisabled() async {
    let fixture = OutputFixture()
    fixture.settings.restoreClipboardAfterPaste = false
    fixture.delivery.outcome = .unconfirmed
    await fixture.manager.deliver(text: "hello", targetPID: 42).value
    XCTAssertEqual(fixture.clipboard.currentText(), "hello")
    fixture.pasteboard.releaseGlobally()
  }

  @MainActor
  func testPasteNotAttemptedKeepsTranscriptionWhenRestoreEnabled() async {
    let fixture = OutputFixture()
    fixture.delivery.outcome = .notAttempted
    await fixture.manager.deliver(text: "hello", targetPID: 42).value
    XCTAssertEqual(fixture.clipboard.currentText(), "hello")
    fixture.pasteboard.releaseGlobally()
  }

  @MainActor
  func testRestoreEnabledAndDisabled() async {
    for restore in [true, false] {
      let fixture = OutputFixture()
      fixture.settings.restoreClipboardAfterPaste = restore
      await fixture.manager.deliver(text: "hello", targetPID: 42).value
      XCTAssertEqual(fixture.delivery.pastedTexts, ["hello"])
      XCTAssertEqual(fixture.clipboard.currentText(), restore ? "original" : "hello")
      fixture.pasteboard.releaseGlobally()
    }
  }

  @MainActor
  func testExternalClipboardChangeIsNeverRestoredOver() async {
    for outcome in [PasteAttemptOutcome.confirmed, .unconfirmed] {
      let fixture = OutputFixture()
      let clipboard = fixture.clipboard
      fixture.delivery.outcome = outcome
      fixture.delivery.onPaste = { clipboard.copy("user copy") }
      await fixture.manager.deliver(text: "hello", targetPID: 42).value
      XCTAssertEqual(fixture.clipboard.currentText(), "user copy")
      fixture.pasteboard.releaseGlobally()
    }
  }

  @MainActor
  func testExternalCopyDuringActivationIsNotPasted() async {
    let fixture = OutputFixture()
    let clipboard = fixture.clipboard
    fixture.delivery.onActivate = { clipboard.copy("user copy") }
    await fixture.manager.deliver(text: "hello", targetPID: 42).value
    XCTAssertEqual(fixture.delivery.pastedTexts, [])
    XCTAssertEqual(fixture.clipboard.currentText(), "user copy")
    fixture.pasteboard.releaseGlobally()
  }

  @MainActor
  func testRepeatedDeliveriesKeepEachClipboardUntilItsPasteFinishes() async {
    let fixture = OutputFixture()
    fixture.delivery.pauseFirstPaste = true
    let firstPasteStarted = expectation(description: "First paste suspended before consuming clipboard")
    fixture.delivery.onFirstPause = { firstPasteStarted.fulfill() }
    let first = fixture.manager.deliver(text: "first 🌍\nline", targetPID: 42)
    await fulfillment(of: [firstPasteStarted], timeout: 5)
    guard let releaseFirstPaste = fixture.delivery.releaseFirstPaste else {
      first.cancel()
      return
    }
    let second = fixture.manager.deliver(text: "second", targetPID: 42)
    await Task.yield()
    XCTAssertEqual(fixture.clipboard.currentText(), "first 🌍\nline")
    releaseFirstPaste.resume()
    await first.value
    await second.value
    XCTAssertEqual(fixture.delivery.pastedTexts, ["first 🌍\nline", "second"])
    XCTAssertEqual(fixture.delivery.consumedClipboard, ["first 🌍\nline", "second"])
    XCTAssertEqual(fixture.clipboard.currentText(), "original")
    fixture.pasteboard.releaseGlobally()
  }
}

@MainActor
private final class OutputFixture {
  let pasteboard = NSPasteboard(name: NSPasteboard.Name("Voicey-output-test-\(UUID().uuidString)"))
  let settings = OutputTestSettings()
  let clipboard: ClipboardManager
  let delivery: OutputTestDelivery
  let manager: OutputManager

  init() {
    clipboard = ClipboardManager(pasteboard: pasteboard)
    delivery = OutputTestDelivery(clipboard: clipboard)
    manager = OutputManager(
      notifications: OutputTestNotifications(), settings: settings,
      permissions: OutputTestPermissions(), clipboard: clipboard, autoPaste: delivery
    )
    clipboard.copy("original")
  }
}

private final class OutputTestDelivery: AutoPasteDelivering {
  let clipboard: ClipboardManager
  var activationSucceeds = true
  var activationCount = 0
  var outcome = PasteAttemptOutcome.confirmed
  var pastedTexts: [String] = []
  var consumedClipboard: [String] = []
  var onPaste: (() -> Void)?
  var onActivate: (() -> Void)?
  var pauseFirstPaste = false
  var onFirstPause: (() -> Void)?
  var releaseFirstPaste: CheckedContinuation<Void, Never>?

  init(clipboard: ClipboardManager) { self.clipboard = clipboard }

  @MainActor
  func activateTarget(pid: pid_t) async -> Bool {
    activationCount += 1
    onActivate?()
    return activationSucceeds
  }

  @MainActor
  func paste(_ text: String, targetPID: pid_t) async -> PasteAttemptOutcome {
    pastedTexts.append(text)
    if pauseFirstPaste, pastedTexts.count == 1 {
      await withCheckedContinuation {
        releaseFirstPaste = $0
        onFirstPause?()
      }
    }
    consumedClipboard.append(clipboard.currentText() ?? "")
    onPaste?()
    return outcome
  }
}

private final class OutputTestSettings: SettingsProviding {
  var selectedModel = SpeechModel.qwen3Small
  var lastSeenDefaultModel: String?
  var lastAppliedDefaultModel: String?
  var launchAtLogin = false
  var showDockIcon = false
  var recordingMode = RecordingMode.manual
  var autoPasteEnabled = true
  var restoreClipboardAfterPaste = true
  var pauseMediaDuringTranscription = false
  var voiceCommandsEnabled = false
  var voiceCommands: [VoiceCommand] = []
  var transcriptionGlossaryEnabled = false
  var transcriptionGlossary = ""
  var transcriptionScreenContextEnabled = false
  var transcriptionScreenContextOCREnabled = false
  var transcriptionLanguageID = ""
  var enableDetailedLogging = false
  func configureLaunchAtLogin(enabled: Bool) {}
  func resetToDefaults() {}
}

private struct OutputTestPermissions: PermissionsProviding {
  func checkMicrophonePermission() async -> Bool { true }
  func requestMicrophonePermission() async -> Bool { true }
  func checkAccessibilityPermission() -> Bool { true }
  func promptForAccessibilityPermission() {}
  func openAccessibilitySettings() {}
  func openMicrophoneSettings() {}
  func checkScreenCapturePermission() -> Bool { false }
  func requestScreenCapturePermission() -> Bool { false }
  func openScreenCaptureSettings() {}
}

private struct OutputTestNotifications: NotificationProviding {
  func showMicrophoneRequiredNotification() {}
  func showNoModelNotification() {}
  func showModelDownloadComplete(model: SpeechModel) {}
  func showModelDownloadFailed(reason: String) {}
  func showModelUpgradeComplete(model: SpeechModel) {}
  func showModelLoading() {}
  func showTranscriptionCopied() {}
  func showTranscriptionError(_ message: String) {}
  func showNetworkError() {}
  func showPerformanceWarning(_ message: String) {}
}
