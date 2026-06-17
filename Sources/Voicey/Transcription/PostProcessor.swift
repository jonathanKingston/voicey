import Foundation
import VoiceyCore
import os

/// Post-processes transcription output via the `voicey-text` worker (expansions, voice
/// commands, formatting, and steering-echo stripping). When LM Studio mode is enabled,
/// vocabulary terms are refined by a local OpenAI-compatible server after the worker pass.
///
/// The bundled `voicey-text` worker is the only post-processing path; there is no
/// in-process Swift fallback. Worker failures throw rather than silently degrading.
final class PostProcessor {
  private let lmStudioPostProcessor = LMStudioPostProcessor()

  // MARK: - Processing

  /// Synchronous entry point (tests / legacy CLI). Prefer `processAsync` on async call paths.
  func process(
    _ result: TranscriptionResult,
    decoderContext: String? = nil,
    steeringTerms: [String] = []
  ) throws -> String {
    let group = DispatchGroup()
    var processedText: String?
    var thrown: Error?
    group.enter()
    Task {
      defer { group.leave() }
      do {
        processedText = try await processViaRustWorker(
          result,
          decoderContext: decoderContext,
          steeringTerms: steeringTerms
        )
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

  func processAsync(
    _ result: TranscriptionResult,
    decoderContext: String? = nil,
    steeringTerms: [String] = []
  ) async throws -> String {
    try await processViaRustWorker(result, decoderContext: decoderContext, steeringTerms: steeringTerms)
  }

  private func processViaRustWorker(
    _ result: TranscriptionResult,
    decoderContext: String?,
    steeringTerms: [String]
  ) async throws -> String {
    let settings = SettingsManager.shared
    do {
      let baseline = try await VoiceyTextWorkerSession.shared.postprocess(
        text: result.text,
        segments: result.segments,
        voiceCommandsEnabled: voiceCommandsEnabled,
        voiceCommands: voiceCommands,
        decoderContext: decoderContext,
        steeringTerms: steeringTerms
      )
      return try await applyLMStudioIfNeeded(
        baseline,
        steeringTerms: steeringTerms,
        settings: settings
      )
    } catch {
      AppLogger.transcription.error(
        "PostProcessor: Rust text worker error: \(error.localizedDescription, privacy: .public)")
      throw error
    }
  }

  private func applyLMStudioIfNeeded(
    _ text: String,
    steeringTerms: [String],
    settings: SettingsProviding
  ) async throws -> String {
    guard settings.transcriptionVocabularyMode == .lmStudioPostProcess else {
      return text
    }
    guard settings.transcriptionGlossaryEnabled || settings.transcriptionScreenContextEnabled else {
      return text
    }

    do {
      return try await lmStudioPostProcessor.refine(
        transcript: text,
        vocabularyTerms: steeringTerms,
        baseURL: settings.lmStudioBaseURL,
        model: settings.lmStudioModel
      )
    } catch {
      AppLogger.transcription.error(
        "PostProcessor: LM Studio post-process failed: \(error.localizedDescription, privacy: .public)"
      )
      return text
    }
  }

  // MARK: - Settings

  private var voiceCommandsEnabled: Bool {
    SettingsManager.shared.voiceCommandsEnabled
  }

  private var voiceCommands: [VoiceCommand] {
    SettingsManager.shared.voiceCommands.filter { $0.enabled }
  }
}
