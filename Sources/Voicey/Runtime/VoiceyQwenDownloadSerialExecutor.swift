import Foundation

/// Serializes Qwen downloads so one shared `voicey-fetch` worker is not overloaded or torn down mid-queue.
actor VoiceyQwenDownloadSerialExecutor {
  static let shared = VoiceyQwenDownloadSerialExecutor()

  func perform(_ operation: @Sendable () async throws -> Void) async throws {
    try await operation()
  }
}
