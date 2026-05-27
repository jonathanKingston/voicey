import Foundation

/// Long-lived `voicey-fetch` JSONL session.
final class VoiceyFetchWorkerSession: @unchecked Sendable {
  static let shared = VoiceyFetchWorkerSession()

  private var process: VoiceyJSONLWorkerProcess?

  private func client() throws -> VoiceyJSONLWorkerProcess {
    if let process { return process }
    guard let path = VoiceyRuntimeConfiguration.fetchWorkerPath else {
      throw VoiceyFetchWorkerError.missingBinary
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
    try VoiceyJSONLResponse.ensureSuccess(response, context: "fetch ping")
  }

  func downloadHFFile(url: String, stagingPath: String, expectedSHA256: String? = nil) async throws {
    var request: [String: Any] = [
      "type": "download_hf_file",
      "id": UUID().uuidString,
      "url": url,
      "staging_path": stagingPath
    ]
    if let expectedSHA256 {
      request["expected_sha256"] = expectedSHA256
    }
    // Large MLX weights (~2.5 GB) need headroom on slower links.
    let response = try await client().send(request: request, timeout: 7_200)
    try VoiceyJSONLResponse.ensureSuccess(response, context: "download_hf_file")
  }

  func stop() {
    process?.stop()
    process = nil
  }
}
