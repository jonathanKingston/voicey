import Foundation

extension AppDelegate: AudioCaptureManagerDelegate {
  func audioCaptureManager(_ manager: AudioCaptureManager, didUpdateLevel level: Float) {
    Task { @MainActor in
      self.appState.audioLevel = level
      self.enforceRecordingDurationLimitIfNeeded()
    }
  }

  func audioCaptureManagerDidDetectSpeechStart(_ manager: AudioCaptureManager) {
    Task { @MainActor in
      guard self.appState.isWaitingForSpeech else { return }
      self.cancelHandsFreeWaitTimeout()
      self.appState.transcriptionState = .recording(startTime: Date())
      AppLogger.audio.info("Hands-Free: Speech detected; recording started")
    }
  }

  func audioCaptureManagerDidDetectSpeechEnd(_ manager: AudioCaptureManager) {
    Task { @MainActor in
      guard self.appState.isRecording else { return }
      AppLogger.audio.info("Hands-Free: Silence hangover reached; stopping recording")
      self.stopRecording()
    }
  }
}
