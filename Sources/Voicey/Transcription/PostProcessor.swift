import Foundation
import VoiceyCore
import os

/// Post-processes transcription output for expansions, voice commands, and formatting.
///
/// Whisper caption noise filtering and segment-based punctuation run only when
/// `TranscriptionResult.segments` is non-empty (benchmark / Whisper backends).
final class PostProcessor {
  // MARK: - Processing

  /// Synchronous entry point (tests / legacy CLI). Prefer `processAsync` on async call paths.
  func process(_ result: TranscriptionResult) throws -> String {
    if VoiceyRuntimeConfiguration.useRustTextPostProcess {
      return try processViaRustWorkerSync(result)
    }
    return processInSwift(result)
  }

  func processAsync(_ result: TranscriptionResult) async throws -> String {
    if VoiceyRuntimeConfiguration.useRustTextPostProcess {
      return try await processViaRustWorker(result)
    }
    return processInSwift(result)
  }

  private func processViaRustWorker(_ result: TranscriptionResult) async throws -> String {
    do {
      return try await VoiceyTextWorkerSession.shared.postprocess(
        text: result.text,
        segments: result.segments,
        voiceCommandsEnabled: voiceCommandsEnabled,
        voiceCommands: voiceCommands
      )
    } catch {
      AppLogger.transcription.error(
        "PostProcessor: Rust text worker error: \(error.localizedDescription, privacy: .public)")
      throw error
    }
  }

  private func processViaRustWorkerSync(_ result: TranscriptionResult) throws -> String {
    let group = DispatchGroup()
    var processedText: String?
    var thrown: Error?
    group.enter()
    Task {
      defer { group.leave() }
      do {
        processedText = try await processViaRustWorker(result)
      } catch {
        thrown = error
      }
    }
    group.wait()
    if let thrown { throw thrown }
    guard let processedText else {
      throw VoiceyTextWorkerError.invalidResponse
    }
    return processedText
  }

  private func processInSwift(_ result: TranscriptionResult) -> String {
    AppLogger.transcription.info("PostProcessor: Input text: \"\(result.text)\"")

    let output = PostProcessBuilder.build(
      PostProcessBuilder.Input(
        text: result.text,
        segments: result.segments.map {
          PostProcessSegment(text: $0.text, startTime: $0.startTime, endTime: $0.endTime)
        },
        voiceCommandsEnabled: voiceCommandsEnabled,
        voiceCommands: voiceCommands
      )
    )

    AppLogger.transcription.info("PostProcessor: Final output: \"\(output)\"")
    return output
  }

  // MARK: - Settings

  private var voiceCommandsEnabled: Bool {
    SettingsManager.shared.voiceCommandsEnabled
  }

  private var voiceCommands: [VoiceCommand] {
    SettingsManager.shared.voiceCommands.filter { $0.enabled }
  }
}
