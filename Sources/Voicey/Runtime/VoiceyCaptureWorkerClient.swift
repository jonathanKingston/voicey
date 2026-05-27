import Foundation

struct VoiceyCaptureWorkerClient {
  let executablePath: String

  init(path: String) {
    self.executablePath = path
  }

  func prewarm() throws {
    _ = try send(request: ["type": "prewarm", "id": UUID().uuidString])
  }

  func recordFixture(durationSeconds: Double) throws -> (shmName: String, sampleCount: Int, sampleRate: Int) {
    let response = try send(request: [
      "type": "record_fixture",
      "id": UUID().uuidString,
      "duration_seconds": durationSeconds
    ])
    guard (response["ok"] as? Bool) == true,
      let shmName = response["shm_name"] as? String,
      let sampleCount = response["sample_count"] as? Int
    else {
      throw VoiceyCaptureWorkerError.failed(response["error"] as? String ?? "capture failed")
    }
    let sampleRate = response["sample_rate"] as? Int ?? 16_000
    return (shmName, sampleCount, sampleRate)
  }

  private func send(request: [String: Any]) throws -> [String: Any] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executablePath)
    process.arguments = []
    let inputPipe = Pipe()
    let outputPipe = Pipe()
    process.standardInput = inputPipe
    process.standardOutput = outputPipe
    try process.run()

    let requestData = try JSONSerialization.data(withJSONObject: request)
    guard var line = String(data: requestData, encoding: .utf8) else {
      throw VoiceyCaptureWorkerError.serializationFailed
    }
    line += "\n"
    inputPipe.fileHandleForWriting.write(line.data(using: .utf8)!)
    inputPipe.fileHandleForWriting.closeFile()

    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    guard let json = try JSONSerialization.jsonObject(with: outputData) as? [String: Any] else {
      throw VoiceyCaptureWorkerError.invalidResponse
    }
    return json
  }
}

enum VoiceyCaptureWorkerError: LocalizedError {
  case serializationFailed
  case invalidResponse
  case failed(String)

  var errorDescription: String? {
    switch self {
    case .serializationFailed:
      return "Unable to serialize capture worker request"
    case .invalidResponse:
      return "Invalid capture worker response"
    case .failed(let message):
      return message
    }
  }
}
