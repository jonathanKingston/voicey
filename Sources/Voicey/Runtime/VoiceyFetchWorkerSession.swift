import Foundation

/// Long-lived `voicey-fetch` JSONL session.
final class VoiceyFetchWorkerSession: @unchecked Sendable {
  static let shared = VoiceyFetchWorkerSession()

  private static let defaultRevision = "main"

  private var process: VoiceyJSONLWorkerProcess?

  private func client() throws -> VoiceyJSONLWorkerProcess {
    if let process { return process }
    let launchConfiguration = try VoiceyFetchWorkerLaunchConfiguration.current()
    let worker = VoiceyJSONLWorkerProcess(
      executablePath: launchConfiguration.executablePath,
      arguments: launchConfiguration.arguments,
      environment: { launchConfiguration.environment }
    )
    process = worker
    return worker
  }

  func ping() async throws {
    let response = try await client().send(request: ["type": "ping", "id": UUID().uuidString])
    try VoiceyJSONLResponse.ensureSuccess(response, context: "fetch ping")
  }

  func listModelFiles(
    modelID: String,
    revision: String = Self.defaultRevision,
    patterns: [String]
  ) async throws -> [String] {
    let response = try await client().send(
      request: [
        "type": "list_model_files",
        "id": UUID().uuidString,
        "model_id": modelID,
        "revision": revision,
        "patterns": patterns,
      ]
    )
    try VoiceyJSONLResponse.ensureSuccess(response, context: "list_model_files")
    guard let files = response["files"] as? [String] else {
      throw VoiceyFetchWorkerError.invalidResponse
    }
    return files
  }

  func downloadModelFile(
    modelID: String,
    revision: String = Self.defaultRevision,
    relativePath: String,
    modelRoot: String,
    expectedSHA256: String? = nil
  ) async throws -> String {
    var request: [String: Any] = [
      "type": "download_model_file",
      "id": UUID().uuidString,
      "model_id": modelID,
      "revision": revision,
      "relative_path": relativePath,
      "model_root": modelRoot,
    ]
    if let expectedSHA256 {
      request["expected_sha256"] = expectedSHA256
    }
    // Large MLX weights (~2.5 GB) need headroom on slower links.
    let response = try await client().send(request: request, timeout: 7_200)
    try VoiceyJSONLResponse.ensureSuccess(response, context: "download_model_file")
    guard let stagedPath = response["staged_path"] as? String, !stagedPath.isEmpty else {
      throw VoiceyFetchWorkerError.invalidResponse
    }
    return stagedPath
  }

  func stop() {
    process?.stop()
    process = nil
  }
}
