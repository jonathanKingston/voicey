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
    voiceCommands: [VoiceCommand]
  ) async throws -> String {
    var request: [String: Any] = [
      "type": "postprocess",
      "id": UUID().uuidString,
      "text": text,
      "voice_commands_enabled": voiceCommandsEnabled,
      "voice_commands": voiceCommands.map(wireVoiceCommand),
      "segments": segments.map(wireSegment)
    ]

    let response = try await client().send(request: request)
    try VoiceyJSONLResponse.ensureSuccess(response, context: "postprocess")

    guard (response["ok"] as? Bool) == true,
      let processedText = response["text"] as? String
    else {
      throw VoiceyTextWorkerError.invalidResponse
    }
    return processedText
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
