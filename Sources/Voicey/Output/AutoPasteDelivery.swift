import AppKit
import Foundation
import VoiceyCore

protocol AutoPasteDelivering {
  @MainActor func activateTarget(pid: pid_t) async -> Bool
  @MainActor func paste(_ text: String, targetPID: pid_t) async -> PasteAttemptOutcome
}

struct SystemAutoPasteDelivery: AutoPasteDelivering {
  @MainActor
  func paste(_ text: String, targetPID: pid_t) async -> PasteAttemptOutcome {
    await AccessibilityPaster.paste(text, targetPID: targetPID)
  }

  @MainActor
  func activateTarget(pid: pid_t) async -> Bool {
    guard let targetApp = NSRunningApplication(processIdentifier: pid),
          pid != ProcessInfo.processInfo.processIdentifier, !targetApp.isTerminated else { return false }
    guard targetApp.activate() else { return false }
    for _ in 0..<50 {
      if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { return true }
      do {
        try await Task.sleep(nanoseconds: 10_000_000)
      } catch {
        AppLogger.output.debug("Auto-paste: target activation cancelled")
        return false
      }
    }
    return false
  }
}
