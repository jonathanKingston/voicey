import Foundation
import VoiceyCore
import os

/// Qwen transcription hints from settings (decoder steering + spoken language).
struct QwenTranscriptionHints: Sendable {
  let decoderContext: String?
  let language: String?
}

/// Builds Qwen decoder steering context on the Voicey host (Accessibility + settings).
enum TranscriptionSteeringContext {
  static func qwenHints(
    settings: SettingsProviding = SettingsManager.shared
  ) async throws -> QwenTranscriptionHints {
    QwenTranscriptionHints(
      decoderContext: try await make(settings: settings),
      language: TranscriptionQwenLanguage.qwenLanguageParameter(
        storedID: settings.transcriptionLanguageID
      )
    )
  }

  static func make(settings: SettingsProviding = SettingsManager.shared) async throws -> String? {
    guard settings.transcriptionGlossaryEnabled || settings.transcriptionScreenContextEnabled else {
      return nil
    }

    if VoiceyRuntimeConfiguration.useRustTextPostProcess {
      return try await makeViaRustWorker(settings: settings)
    }
    return makeInSwift(settings: settings)
  }

  private static func makeViaRustWorker(settings: SettingsProviding) async throws -> String? {
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
      return result.decoderContext
    } catch {
      AppLogger.transcription.error(
        "Steering: Rust text worker error: \(error.localizedDescription, privacy: .public)")
      throw error
    }
  }

  private static func makeInSwift(settings: SettingsProviding) -> String? {
    let snapshot = settings.transcriptionScreenContextEnabled
      ? ScreenContextStore.shared.currentSnapshot()
      : nil
    let output = SteeringContextBuilder.build(
      SteeringContextBuilder.Input(
        manualGlossaryEnabled: settings.transcriptionGlossaryEnabled,
        manualGlossary: settings.transcriptionGlossary,
        screenContextEnabled: settings.transcriptionScreenContextEnabled,
        snapshot: snapshot
      )
    )
    logSteeringResult(terms: output.terms, context: output.decoderContext, settings: settings)
    return output.decoderContext
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
