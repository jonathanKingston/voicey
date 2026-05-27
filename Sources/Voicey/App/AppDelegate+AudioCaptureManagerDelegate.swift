import Foundation

extension AppDelegate: AudioCaptureManagerDelegate {
  func audioCaptureManager(_ manager: AudioCaptureManager, didUpdateLevel level: Float) {
    Task { @MainActor in
      self.appState.audioLevel = level
      self.enforceRecordingDurationLimitIfNeeded()
    }
  }
}
