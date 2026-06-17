import Foundation
import VoiceyCore

/// Post-processing for benchmark CLI — always uses `voicey-text`, never Swift duplicates.
enum BenchmarkPostProcessor {
  struct Options: Sendable {
    var vocabularyRepairEnabled = false
    var itnEnabled = false
    var steeringTerms: [String] = []

    static let `default` = Options()
  }

  static func process(
    _ result: TranscriptionResult,
    options: Options = .default
  ) async throws -> String {
    try BenchmarkRustRequirements.requireTextWorker()
    return try await VoiceyTextWorkerSession.shared.postprocess(
      text: result.text,
      segments: result.segments,
      voiceCommandsEnabled: SettingsManager.shared.voiceCommandsEnabled,
      voiceCommands: SettingsManager.shared.voiceCommands.filter(\.enabled),
      steeringTerms: options.steeringTerms,
      vocabularyRepairEnabled: options.vocabularyRepairEnabled,
      itnEnabled: options.itnEnabled
    )
  }
}
