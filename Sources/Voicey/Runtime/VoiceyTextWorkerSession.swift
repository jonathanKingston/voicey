import Foundation
import VoiceyCore

/// Long-lived `voicey-text` JSONL session.
final class VoiceyTextWorkerSession: @unchecked Sendable {
  static let shared = VoiceyTextWorkerSession()

  private var process: VoiceyJSONLWorkerProcess?

  private func client() throws -> VoiceyJSONLWorkerProcess {
    if let process { return process }
    guard let path = VoiceyRuntimeConfiguration.textWorkerPath else {
      throw VoiceyTextWorkerError.missingBinary
    }
    let worker = VoiceyJSONLWorkerProcess(
      executablePath: path,
      environment: { ProcessInfo.processInfo.environment }
    )
    process = worker
    return worker
  }

  func ping() async throws {
    let response = try await client().send(request: ["type": "ping", "id": UUID().uuidString])
    try VoiceyJSONLResponse.ensureSuccess(response, context: "text ping")
  }

  func postprocess(
    text: String,
    segments: [TranscriptionSegment],
    voiceCommandsEnabled: Bool,
    voiceCommands: [VoiceCommand],
    decoderContext: String? = nil,
    steeringTerms: [String] = [],
    vocabularyRepairEnabled: Bool = false,
    itnEnabled: Bool = false
  ) async throws -> String {
    var request: [String: Any] = [
      "type": "postprocess",
      "id": UUID().uuidString,
      "text": text,
      "voice_commands_enabled": voiceCommandsEnabled,
      "voice_commands": voiceCommands.map(wireVoiceCommand),
      "segments": segments.map(wireSegment),
      "steering_terms": steeringTerms,
      "vocabulary_repair_enabled": vocabularyRepairEnabled,
      "itn_enabled": itnEnabled
    ]
    if let decoderContext {
      request["decoder_context"] = decoderContext
    }

    let response = try await client().send(request: request)
    try VoiceyJSONLResponse.ensureSuccess(response, context: "postprocess")

    guard (response["ok"] as? Bool) == true,
      let processedText = response["text"] as? String
    else {
      throw VoiceyTextWorkerError.invalidResponse
    }
    return processedText
  }

  func buildSteeringContext(
    manualGlossaryEnabled: Bool,
    manualGlossary: String,
    screenContextEnabled: Bool,
    snapshot: ScreenContextSnapshot?,
    maxTerms: Int = ScreenTermSelector.defaultMaxTerms
  ) async throws -> (decoderContext: String?, terms: [String]) {
    var request: [String: Any] = [
      "type": "build_steering_context",
      "id": UUID().uuidString,
      "manual_glossary_enabled": manualGlossaryEnabled,
      "manual_glossary": manualGlossary,
      "screen_context_enabled": screenContextEnabled,
      "max_terms": maxTerms
    ]
    if let snapshot {
      request["snapshot"] = [
        "query_text": snapshot.queryText,
        "corpus_chunks": snapshot.corpusChunks
      ]
    }

    let response = try await client().send(request: request)
    try VoiceyJSONLResponse.ensureSuccess(response, context: "build_steering_context")

    guard (response["ok"] as? Bool) == true else {
      throw VoiceyTextWorkerError.invalidResponse
    }
    let terms = response["terms"] as? [String] ?? []
    let decoderContext = response["decoder_context"] as? String
    return (decoderContext, terms)
  }

  func stop() {
    process?.stop()
    process = nil
  }

  private func wireSegment(_ segment: TranscriptionSegment) -> [String: Any] {
    [
      "text": segment.text,
      "start_time": segment.startTime,
      "end_time": segment.endTime
    ]
  }

  private func wireVoiceCommand(_ command: VoiceCommand) -> [String: Any] {
    var payload: [String: Any] = [
      "phrase": command.phrase,
      "enabled": command.enabled
    ]
    switch command.action {
    case .newLine:
      payload["action"] = "new_line"
    case .newParagraph:
      payload["action"] = "new_paragraph"
    case .scratchThat:
      payload["action"] = "scratch_that"
    case .custom(let replacement):
      payload["action"] = "custom"
      payload["replacement"] = replacement
    }
    return payload
  }
}
