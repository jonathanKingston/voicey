import Foundation
import VoiceyCore

enum VoiceyArchiveWorkerError: LocalizedError {
  case missingBinary
  case invalidResponse
  case failed(String)

  var errorDescription: String? {
    switch self {
    case .missingBinary:
      return "voicey-archive binary not found"
    case .invalidResponse:
      return "Invalid voicey-archive response"
    case .failed(let message):
      return message
    }
  }
}

/// Long-lived `voicey-archive` JSONL session.
final class VoiceyArchiveWorkerSession: @unchecked Sendable {
  static let shared = VoiceyArchiveWorkerSession()

  private var process: VoiceyJSONLWorkerProcess?

  private func client() throws -> VoiceyJSONLWorkerProcess {
    if let process { return process }
    guard let path = VoiceyRuntimeConfiguration.archiveWorkerPath else {
      throw VoiceyArchiveWorkerError.missingBinary
    }
    let worker = VoiceyJSONLWorkerProcess(executablePath: path)
    process = worker
    return worker
  }

  func appendUtterance(
    archiveRoot: URL,
    audio: [String: Any],
    metadata: [String: Any],
    snapshot: UtteranceArchiveScreenSnapshot?,
    maxEntries: Int = SessionArchiveStore.defaultMaxEntries
  ) async throws {
    var request: [String: Any] = [
      "type": "append_utterance",
      "id": UUID().uuidString,
      "archive_root": archiveRoot.path,
      "max_entries": maxEntries,
      "audio": audio,
      "metadata": metadata
    ]
    if let snapshot {
      request["snapshot"] = [
        "query_text": snapshot.queryText,
        "corpus_chunks": snapshot.corpusChunks
      ]
    }
    let response = try await client().send(request: request, timeout: 120)
    guard response["type"] as? String == "archive_result" else {
      throw VoiceyArchiveWorkerError.invalidResponse
    }
    guard response["ok"] as? Bool == true else {
      throw VoiceyArchiveWorkerError.failed(response["error"] as? String ?? "append failed")
    }
  }

  func deleteAll(archiveRoot: URL) async throws {
    let response = try await client().send(
      request: [
        "type": "delete_all",
        "id": UUID().uuidString,
        "archive_root": archiveRoot.path
      ],
      timeout: 30
    )
    guard response["type"] as? String == "delete_all_result" else {
      throw VoiceyArchiveWorkerError.invalidResponse
    }
    guard response["ok"] as? Bool == true else {
      throw VoiceyArchiveWorkerError.failed(response["error"] as? String ?? "delete_all failed")
    }
  }

  func stop() {
    process?.stop()
    process = nil
  }
}
