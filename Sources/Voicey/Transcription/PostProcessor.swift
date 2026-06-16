import Foundation
import VoiceyCore
import os

/// Post-processes transcription output via the `voicey-text` worker (expansions, voice
/// commands, formatting, and steering-echo stripping).
///
/// The bundled `voicey-text` worker is the only post-processing path; there is no
/// in-process Swift fallback. Worker failures throw rather than silently degrading.
final class PostProcessor {
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
    let settings = SettingsManager.shared
    if settings.localLMRefinementEnabled {
      let refinedText = try await LocalLMTextRefiner.refine(
        transcript: result.text,
        steeringTerms: steeringTerms,
        decoderContext: decoderContext
      )
      let refinedResult = TranscriptionResult(
        text: refinedText,
        segments: result.segments,
        language: result.language,
        processingTime: result.processingTime,
        performanceMetrics: result.performanceMetrics
      )
      return try await processViaRustWorker(
        refinedResult,
        decoderContext: nil,
        steeringTerms: []
      )
    }

    return try await processViaRustWorker(
      result,
      decoderContext: decoderContext,
      steeringTerms: steeringTerms
    )
  }

  private func processViaRustWorker(
    _ result: TranscriptionResult,
    decoderContext: String?,
    steeringTerms: [String]
  ) async throws -> String {
    do {
      return try await VoiceyTextWorkerSession.shared.postprocess(
        text: result.text,
        segments: result.segments,
        voiceCommandsEnabled: voiceCommandsEnabled,
        voiceCommands: voiceCommands,
        decoderContext: decoderContext,
        steeringTerms: steeringTerms
      )
    } catch {
      AppLogger.transcription.error(
        "PostProcessor: Rust text worker error: \(error.localizedDescription, privacy: .public)")
      throw error
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
