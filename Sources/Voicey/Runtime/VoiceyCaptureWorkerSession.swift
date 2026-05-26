import Foundation

/// Long-lived `voicey-capture` JSONL session.
final class VoiceyCaptureWorkerSession: @unchecked Sendable {
  static let shared = VoiceyCaptureWorkerSession()

  private var process: VoiceyJSONLWorkerProcess?

  private func client() throws -> VoiceyJSONLWorkerProcess {
    if let process { return process }
    guard let path = VoiceyRuntimeConfiguration.captureWorkerPath else {
      throw VoiceyCaptureWorkerError.missingBinary
    }
    let worker = VoiceyJSONLWorkerProcess(executablePath: path)
    process = worker
    return worker
  }

  func startRecording() async throws {
    let response = try await client().send(
      request: ["type": "start_recording", "id": UUID().uuidString]
    )
    try VoiceyJSONLResponse.ensureSuccess(response, context: "start_recording")
  }

  func stopRecording() async throws -> [Float] {
    let response = try await client().send(
      request: ["type": "stop_recording", "id": UUID().uuidString],
      timeout: 120
    )
    try VoiceyJSONLResponse.ensureSuccess(response, context: "stop_recording")
    guard let shmName = response["shm_name"] as? String,
      let sampleCount = response["sample_count"] as? Int
    else {
      throw VoiceyCaptureWorkerError.invalidResponse
    }
    defer { SharedMemoryPCM.remove(name: shmName) }
    return try SharedMemoryPCM.read(name: shmName, sampleCount: sampleCount)
  }

  func prewarm() async throws {
    let response = try await client().send(
      request: ["type": "prewarm", "id": UUID().uuidString]
    )
    try VoiceyJSONLResponse.ensureSuccess(response, context: "capture prewarm")
  }

  func recordFixture(durationSeconds: Double) async throws -> (shmName: String, sampleCount: Int, sampleRate: Int) {
    let response = try await client().send(
      request: [
        "type": "record_fixture",
        "id": UUID().uuidString,
        "duration_seconds": durationSeconds
      ]
    )
    try VoiceyJSONLResponse.ensureSuccess(response, context: "record_fixture")
    guard let shmName = response["shm_name"] as? String,
      let sampleCount = response["sample_count"] as? Int
    else {
      throw VoiceyCaptureWorkerError.invalidResponse
    }
    let sampleRate = response["sample_rate"] as? Int ?? 16_000
    return (shmName, sampleCount, sampleRate)
  }

  func stop() {
    process?.stop()
    process = nil
  }
}

extension VoiceyCaptureWorkerError {
  static var missingBinary: VoiceyCaptureWorkerError { .failed("voicey-capture binary not found") }
}
