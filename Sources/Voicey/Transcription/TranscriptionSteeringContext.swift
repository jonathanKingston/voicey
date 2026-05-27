import Foundation
import VoiceyCore
import os

/// Builds Qwen decoder steering context on the Voicey host (Accessibility + settings).
enum TranscriptionSteeringContext {
  static func make(settings: SettingsProviding = SettingsManager.shared) -> String? {
    guard settings.transcriptionGlossaryEnabled || settings.transcriptionScreenContextEnabled else {
      return nil
    }

    var manualTerms: [String] = []
    var screenTerms: [String] = []
    if settings.transcriptionGlossaryEnabled {
      manualTerms = TranscriptionGlossary.parseTerms(settings.transcriptionGlossary)
    }
    if settings.transcriptionScreenContextEnabled {
      screenTerms = ScreenContextStore.shared.consumeScreenTerms(
        manualGlossaryForQuery: settings.transcriptionGlossary
      )
    }

    let terms = manualTerms + screenTerms
    let context = TranscriptionGlossary.decodingContext(terms: terms)

    if terms.isEmpty {
      AppLogger.transcription.info(
        "Steering: enabled but no terms (manual=\(manualTerms.count) screen=\(screenTerms.count))"
      )
    } else {
      AppLogger.transcription.info(
        "Steering: manual=\(manualTerms.count) screen=\(screenTerms.count) total=\(terms.count) contextChars=\(context?.count ?? 0)"
      )
      if settings.enableDetailedLogging {
        let termsLine = terms.joined(separator: ", ")
        AppLogger.transcription.info("Steering terms: \(termsLine, privacy: .private)")
        if let context {
          AppLogger.transcription.info("Steering decoder_context: \(context, privacy: .private)")
        }
      }
    }

    return context
  }
}
