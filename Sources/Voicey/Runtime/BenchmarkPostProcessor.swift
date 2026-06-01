import Foundation
import VoiceyCore

/// Post-processing for benchmark CLI — always uses `voicey-text`, never Swift duplicates.
enum BenchmarkPostProcessor {
  static func process(_ result: TranscriptionResult) async throws -> String {
    try BenchmarkRustRequirements.requireTextWorker()
    return try await VoiceyTextWorkerSession.shared.postprocess(
      text: result.text,
      segments: result.segments,
      voiceCommandsEnabled: SettingsManager.shared.voiceCommandsEnabled,
      voiceCommands: SettingsManager.shared.voiceCommands.filter(\.enabled)
    )
  }
}
