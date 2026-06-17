import Foundation
import VoiceyCore
import os

/// Qwen transcription hints from settings (decoder steering + spoken language).
///
/// `steeringTerms` are retained alongside the decoder context so the `voicey-text`
/// post-process can strip regurgitated steering vocabulary before paste.
struct QwenTranscriptionHints: Sendable {
  let decoderContext: String?
  let language: String?
  let steeringTerms: [String]
}

/// Builds Qwen decoder steering context on the Voicey host (Accessibility + settings).
///
/// Steering terms + decoder context are resolved via the `voicey-text` worker; there is
/// no in-process Swift builder.
enum TranscriptionSteeringContext {
  static func qwenHints(
    settings: SettingsProviding = SettingsManager.shared
  ) async throws -> QwenTranscriptionHints {
    let language = TranscriptionQwenLanguage.qwenLanguageParameter(
      storedID: settings.transcriptionLanguageID
    )

    guard settings.transcriptionGlossaryEnabled || settings.transcriptionScreenContextEnabled else {
      return QwenTranscriptionHints(decoderContext: nil, language: language, steeringTerms: [])
    }

    if settings.transcriptionScreenContextEnabled {
      let captureOutcome = await ScreenContextStore.shared.waitForCaptureIfNeeded()
      logCaptureWaitOutcome(captureOutcome)
    }

    let snapshot = settings.transcriptionScreenContextEnabled
      ? ScreenContextStore.shared.currentSnapshot()
      : nil

    do {
      let result = try await VoiceyTextWorkerSession.shared.buildSteeringContext(
        manualGlossaryEnabled: settings.transcriptionGlossaryEnabled,
        manualGlossary: settings.transcriptionGlossary,
        screenContextEnabled: settings.transcriptionScreenContextEnabled,
        snapshot: snapshot
      )
      logSteeringResult(terms: result.terms, context: result.decoderContext, settings: settings)
      let decoderContext =
        settings.transcriptionVocabularyMode == .decoderSteering ? result.decoderContext : nil
      if settings.transcriptionVocabularyMode == .lmStudioPostProcess, result.decoderContext != nil {
        AppLogger.transcription.info(
          "Steering: LM Studio post-process mode — skipping decoder context for ASR"
        )
      }
      return QwenTranscriptionHints(
        decoderContext: decoderContext,
        language: language,
        steeringTerms: result.terms
      )
    } catch {
      AppLogger.transcription.error(
        "Steering: Rust text worker error: \(error.localizedDescription, privacy: .public)")
      throw error
    }
  }

  private static func logCaptureWaitOutcome(_ outcome: ScreenContextCaptureWaitOutcome) {
    switch outcome {
    case .inactive:
      AppLogger.transcription.debug("ScreenContext capture: inactive")
    case .ready:
      AppLogger.transcription.info("ScreenContext capture: ready")
    case .timeout:
      AppLogger.transcription.info(
        "ScreenContext capture: timeout (steering may omit screen terms)")
    }
  }

  private static func logSteeringResult(
    terms: [String],
    context: String?,
    settings: SettingsProviding
  ) {
    if terms.isEmpty {
      AppLogger.transcription.info("Steering: enabled but no terms")
    } else {
      AppLogger.transcription.info(
        "Steering: total=\(terms.count) contextChars=\(context?.count ?? 0)"
      )
      if settings.enableDetailedLogging {
        let termsLine = terms.joined(separator: ", ")
        AppLogger.transcription.info("Steering terms: \(termsLine, privacy: .private)")
        if let context {
          AppLogger.transcription.info("Steering decoder_context: \(context, privacy: .private)")
        }
      }
    }
  }
}
