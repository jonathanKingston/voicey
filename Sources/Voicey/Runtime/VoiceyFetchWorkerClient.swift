import Foundation

struct VoiceyFetchWorkerClient {
  let executablePath: String

  init?() {
    guard let path = VoiceyRuntimeConfiguration.fetchWorkerPath else { return nil }
    self.executablePath = path
  }

  func ping() throws {
    _ = try send(request: ["type": "ping", "id": UUID().uuidString])
  }

  private func send(request: [String: Any]) throws -> [String: Any] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executablePath)
    let inputPipe = Pipe()
    let outputPipe = Pipe()
    process.standardInput = inputPipe
    process.standardOutput = outputPipe
    try process.run()

    let requestData = try JSONSerialization.data(withJSONObject: request)
    guard var line = String(data: requestData, encoding: .utf8) else {
      throw VoiceyFetchWorkerError.serializationFailed
    }
    line += "\n"
    inputPipe.fileHandleForWriting.write(line.data(using: .utf8)!)
    inputPipe.fileHandleForWriting.closeFile()

    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    guard let json = try JSONSerialization.jsonObject(with: outputData) as? [String: Any] else {
      throw VoiceyFetchWorkerError.invalidResponse
    }
    return json
  }
}

enum VoiceyFetchWorkerError: LocalizedError {
  case serializationFailed
  case invalidResponse

  var errorDescription: String? {
    switch self {
    case .serializationFailed:
      return "Unable to serialize fetch worker request"
    case .invalidResponse:
      return "Invalid fetch worker response"
    }
  }
}
