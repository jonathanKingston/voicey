import Foundation

extension AppDelegate: AudioCaptureManagerDelegate {
  func audioCaptureManager(_ manager: AudioCaptureManager, didUpdateLevel level: Float) {
    Task { @MainActor in
      self.appState.audioLevel = level
      self.enforceRecordingDurationLimitIfNeeded()
    }
  }

  func audioCaptureManager(_ manager: AudioCaptureManager, didCaptureSamples samples: [Float]) {
    incrementalTranscriptionCoordinator?.append(samples: samples)
  }
}
