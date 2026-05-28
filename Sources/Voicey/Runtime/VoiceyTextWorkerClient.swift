import Foundation

struct VoiceyTextWorkerClient {
  init?() {
    guard VoiceyRuntimeConfiguration.textWorkerPath != nil else { return nil }
  }

  func ping() async throws {
    try await VoiceyTextWorkerSession.shared.ping()
  }
}

enum VoiceyTextWorkerError: LocalizedError {
  case missingBinary
  case serializationFailed
  case invalidResponse

  var errorDescription: String? {
    switch self {
    case .missingBinary:
      return "voicey-text binary not found (run make build-rust)"
    case .serializationFailed:
      return "Unable to serialize text worker request"
    case .invalidResponse:
      return "Invalid text worker response"
    }
  }
}
