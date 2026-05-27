import Foundation
import VoiceyCore

/// Builds Qwen decoder steering context on the Voicey host (Accessibility + settings).
enum TranscriptionSteeringContext {
  static func make(settings: SettingsProviding = SettingsManager.shared) -> String? {
    guard settings.transcriptionGlossaryEnabled || settings.transcriptionScreenContextEnabled else {
      return nil
    }

    var terms: [String] = []
    if settings.transcriptionGlossaryEnabled {
      terms.append(contentsOf: TranscriptionGlossary.parseTerms(settings.transcriptionGlossary))
    }
    if settings.transcriptionScreenContextEnabled {
      let screenTerms = ScreenContextStore.shared.consumeScreenTerms(
        manualGlossaryForQuery: settings.transcriptionGlossary
      )
      terms.append(contentsOf: screenTerms)
    }

    return TranscriptionGlossary.decodingContext(terms: terms)
  }
}
