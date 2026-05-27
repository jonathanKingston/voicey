import Foundation

struct VoiceyFetchWorkerClient {
  init?() {
    guard VoiceyRuntimeConfiguration.fetchWorkerPath != nil else { return nil }
  }

  func ping() async throws {
    try await VoiceyFetchWorkerSession.shared.ping()
  }
}

enum VoiceyFetchWorkerError: LocalizedError {
  case missingBinary
  case serializationFailed
  case invalidResponse

  var errorDescription: String? {
    switch self {
    case .missingBinary:
      return "voicey-fetch binary not found (run make build-rust)"
    case .serializationFailed:
      return "Unable to serialize fetch worker request"
    case .invalidResponse:
      return "Invalid fetch worker response"
    }
  }
}
