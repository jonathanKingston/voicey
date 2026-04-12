import Foundation
import os
import VoiceyCore

/// Post-processes transcription output for punctuation, formatting, and voice commands
final class PostProcessor {
  private let coreProcessor = CorePostProcessor()

  /// Get current voice commands settings (read fresh each time)
  private var voiceCommandsEnabled: Bool {
    SettingsManager.shared.voiceCommandsEnabled
  }

  private var voiceCommands: [VoiceCommand] {
    SettingsManager.shared.voiceCommands.filter { $0.enabled }
  }

  // MARK: - Processing

  func process(_ result: TranscriptionResult) -> String {
    AppLogger.transcription.info("PostProcessor: Input text: \"\(result.text)\"")

    let coreResult = CoreTranscriptionResult(
      text: result.text,
      segments: result.segments.map {
        CoreTranscriptionSegment(
          text: $0.text,
          startTime: $0.startTime,
          endTime: $0.endTime
        )
      }
    )
    let configuration = CorePostProcessorConfiguration(
      voiceCommandsEnabled: voiceCommandsEnabled,
      voiceCommands: voiceCommands,
      textExpansions: TextCleanup.defaultTextExpansions
    )
    let processedText = coreProcessor.process(coreResult, configuration: configuration)

    AppLogger.transcription.info("PostProcessor: Final output: \"\(processedText)\"")
    return processedText
  }
}
