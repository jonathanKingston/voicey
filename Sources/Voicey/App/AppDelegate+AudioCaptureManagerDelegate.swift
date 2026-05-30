import Foundation

extension AppDelegate: AudioCaptureManagerDelegate {
  func audioCaptureManager(_ manager: AudioCaptureManager, didUpdateLevel level: Float) {
    Task { @MainActor in
      self.appState.audioLevel = level
      self.enforceRecordingDurationLimitIfNeeded()
    }
  }

  func audioCaptureManager(_ manager: AudioCaptureManager, didCaptureSamples samples: [Float]) {
    guard !appState.handsFreeSessionActive else { return }
    incrementalTranscriptionCoordinator?.append(samples: samples)
  }

  func audioCaptureManagerDidDetectSpeechStart(_ manager: AudioCaptureManager) {
    Task { @MainActor in
      guard self.appState.handsFreeSessionActive, self.appState.isWaitingForSpeech else { return }
      self.cancelHandsFreeWaitTimeout()
      self.cancelHandsFreeAutoCommitTimeout()
      self.appState.transcriptionState = .recording(startTime: Date())
      AppLogger.audio.info("Hands-Free: Speech detected; recording started")
    }
  }

  func audioCaptureManagerDidDetectSpeechEnd(_ manager: AudioCaptureManager) {
    Task { @MainActor in
      guard self.appState.handsFreeSessionActive else { return }
      guard self.appState.isRecording else {
        manager.recoverHandsFreeDetectorForNextUtterance()
        return
      }
      AppLogger.audio.info("Hands-Free: Silence hangover reached; finalizing utterance")
      self.finishHandsFreeUtteranceAndContinueListening()
    }
  }
}
