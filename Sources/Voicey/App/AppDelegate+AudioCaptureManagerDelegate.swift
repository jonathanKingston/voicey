import Foundation

extension AppDelegate: AudioCaptureManagerDelegate {
  func audioCaptureManager(_ manager: AudioCaptureManager, didUpdateLevel level: Float) {
    Task { @MainActor in
      self.appState.audioLevel = level
      self.enforceRecordingDurationLimitIfNeeded()
    }
  }

  func audioCaptureManager(_ manager: AudioCaptureManager, didCaptureSamples samples: [Float]) {
    if appState.handsFreeSessionActive {
      guard appState.isRecording else { return }
    }
    incrementalTranscriptionCoordinator?.append(samples: samples)
  }

  func audioCaptureManagerDidDetectSpeechStart(_ manager: AudioCaptureManager) {
    Task { @MainActor in
      guard self.appState.handsFreeSessionActive, self.appState.isWaitingForSpeech else { return }
      // Do not reset the incremental coordinator while the previous utterance is still
      // flushing; that races with flushAndFinish and can corrupt in-flight chunk state.
      guard !self.appState.isHandsFreeUtteranceFlushInProgress else { return }
      self.cancelHandsFreeWaitTimeout()
      self.incrementalTranscriptionCoordinator?.reset()
      self.appState.partialTranscription = ""
      self.appState.isCatchingUpTranscription = false
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
