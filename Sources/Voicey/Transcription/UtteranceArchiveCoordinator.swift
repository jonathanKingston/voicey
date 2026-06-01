import CryptoKit
import Foundation
import VoiceyCore
import os

/// Persists utterances via `voicey-archive` when dictation history is enabled.
enum UtteranceArchiveCoordinator {
  private static let sessionArchiveEnvironmentKey = "VOICEY_SESSION_ARCHIVE"

  static func isEnabled(settings: SettingsProviding = SettingsManager.shared) -> Bool {
    if ProcessInfo.processInfo.environment[sessionArchiveEnvironmentKey] == "1" {
      return true
    }
    return settings.keepDictationHistoryLocally
  }

  static func archiveUtterance(
    capturedAudio: CapturedAudio,
    outcome: UtteranceArchiveOutcome,
    rawText: String,
    processedText: String,
    errorMessage: String?,
    partialTranscription: String?,
    model: SpeechModel,
    settings: SettingsProviding = SettingsManager.shared,
    steering: QwenTranscriptionHints?,
    screenSnapshot: ScreenContextSnapshot?,
    targetAppBundleID: String?
  ) {
    guard isEnabled(settings: settings) else { return }
    guard SessionArchiveBackend.isAvailable else {
      AppLogger.transcription.error(
        "Session archive: neither voicey-capture nor voicey-archive binary found")
      return
    }

    let audioWire: [String: Any]
    do {
      audioWire = try wireAudioSource(from: capturedAudio)
    } catch {
      AppLogger.transcription.error(
        "Session archive: \(error.localizedDescription, privacy: .public)")
      return
    }

    let snapshot: UtteranceArchiveScreenSnapshot?
    if settings.transcriptionScreenContextEnabled, let screenSnapshot,
      !screenSnapshot.queryText.isEmpty || !screenSnapshot.corpusChunks.isEmpty {
      snapshot = UtteranceArchiveScreenSnapshot(snapshot: screenSnapshot)
    } else {
      snapshot = nil
    }

    var metadata: [String: Any] = [
      "outcome": wireOutcome(outcome),
      "model_id": model.rawValue,
      "language_id": settings.transcriptionLanguageID,
      "raw_text": rawText,
      "processed_text": processedText,
      "steering_terms": steering?.steeringTerms ?? [],
      "glossary_enabled": settings.transcriptionGlossaryEnabled,
      "screen_context_enabled": settings.transcriptionScreenContextEnabled,
      "runtime": (VoiceyRuntimeConfiguration.mode == .multiprocess ? "multiprocess" : "in-process")
    ]
    if let errorMessage { metadata["error_message"] = errorMessage }
    if let partialTranscription { metadata["partial_transcription"] = partialTranscription }
    if let hash = steering?.decoderContext.flatMap({ sha256Hex(of: $0) }) {
      metadata["decoder_context_sha256"] = hash
    }
    if let targetAppBundleID { metadata["app_bundle_id"] = targetAppBundleID }
    if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
      metadata["voicey_version"] = version
    }

    let root = SessionArchiveStore.shared.rootURL()
    Task {
      do {
        try await SessionArchiveBackend.appendUtterance(
          archiveRoot: root,
          audio: audioWire,
          metadata: metadata,
          snapshot: snapshot
        )
        await MainActor.run {
          NotificationCenter.default.post(name: .voiceySessionArchiveDidChange, object: nil)
        }
      } catch {
        AppLogger.transcription.error(
          "Session archive write failed: \(error.localizedDescription, privacy: .public)")
      }
    }
  }

  static func outcome(
    errorMessage: String?,
    hasDeliverableText: Bool
  ) -> UtteranceArchiveOutcome {
    if errorMessage != nil { return .error }
    if !hasDeliverableText { return .emptyDelivery }
    return .completed
  }

  private static func wireOutcome(_ outcome: UtteranceArchiveOutcome) -> String {
    switch outcome {
    case .completed: return "completed"
    case .emptyDelivery: return "empty_delivery"
    case .error: return "error"
    }
  }

  private static func wireAudioSource(from capturedAudio: CapturedAudio) throws -> [String: Any] {
    switch capturedAudio {
    case .inMemory(let samples):
      guard !samples.isEmpty else {
        throw VoiceyArchiveWorkerError.failed("empty audio")
      }
      return [
        "source": "samples",
        "samples": samples.map { Double($0) }
      ]
    case .sharedBuffer(let handle):
      guard handle.sampleCount > 0 else {
        throw VoiceyArchiveWorkerError.failed("empty audio")
      }
      var payload: [String: Any] = [
        "source": "pcm_shm",
        "shm_name": handle.shmName,
        "sample_count": handle.sampleCount
      ]
      if handle.sampleOffset > 0 {
        payload["sample_offset"] = handle.sampleOffset
      }
      return payload
    }
  }

  private static func sha256Hex(of text: String) -> String {
    let digest = SHA256.hash(data: Data(text.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }
}
