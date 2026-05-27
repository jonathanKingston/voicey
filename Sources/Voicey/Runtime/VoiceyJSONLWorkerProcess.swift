import Foundation
import os

/// Long-lived JSONL subprocess client (one response line per request `id`).
final class VoiceyJSONLWorkerProcess: @unchecked Sendable {
  private let executablePath: String
  private let arguments: [String]
  private let environmentBuilder: () -> [String: String]
  private var process: Process?
  private var stdinHandle: FileHandle?
  private var stdoutBuffer = ""
  private var pending: [String: CheckedContinuation<[String: Any], Error>] = [:]
  private var timeoutWorkItems: [String: DispatchWorkItem] = [:]
  private let queue = DispatchQueue(label: "work.voicey.jsonl-worker")

  init(
    executablePath: String,
    arguments: [String] = [],
    environment: @escaping () -> [String: String] = { ProcessInfo.processInfo.environment }
  ) {
    self.executablePath = executablePath
    self.arguments = arguments
    self.environmentBuilder = environment
  }

  func startIfNeeded() throws {
    if let process, process.isRunning { return }
    stop()

    let process = Process()
    process.executableURL = URL(fileURLWithPath: executablePath)
    process.arguments = arguments
    process.environment = environmentBuilder()

    let inputPipe = Pipe()
    let outputPipe = Pipe()
    process.standardInput = inputPipe
    process.standardOutput = outputPipe
    process.standardError = Pipe()

    outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
      self?.queue.async {
        self?.consumeStdout(chunk)
      }
    }

    process.terminationHandler = { [weak self] _ in
      self?.queue.async {
        self?.failAllPending(VoiceyJSONLWorkerError.notRunning)
      }
    }

    try process.run()
    self.process = process
    self.stdinHandle = inputPipe.fileHandleForWriting
  }

  func send(request: [String: Any], timeout: TimeInterval = 120) async throws -> [String: Any] {
    try startIfNeeded()
    let id = request["id"] as? String ?? UUID().uuidString
    var payload = request
    payload["id"] = id

    let data = try JSONSerialization.data(withJSONObject: payload)
    guard var line = String(data: data, encoding: .utf8) else {
      throw VoiceyJSONLWorkerError.serializationFailed
    }
    line += "\n"
    guard let lineData = line.data(using: .utf8) else {
      throw VoiceyJSONLWorkerError.serializationFailed
    }

    return try await withCheckedThrowingContinuation { continuation in
      queue.async {
        guard self.process?.isRunning == true else {
          continuation.resume(throwing: VoiceyJSONLWorkerError.notRunning)
          return
        }
        self.pending[id] = continuation
        self.scheduleTimeout(for: id, seconds: timeout)
        self.stdinHandle?.write(lineData)
      }
    }
  }

  func stop() {
    queue.sync {
      stdinHandle?.closeFile()
      process?.terminate()
      process = nil
      stdinHandle = nil
      stdoutBuffer = ""
      cancelAllTimeouts()
      failAllPending(VoiceyJSONLWorkerError.notRunning)
    }
  }

  private func scheduleTimeout(for id: String, seconds: TimeInterval) {
    timeoutWorkItems[id]?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      if let continuation = self.pending.removeValue(forKey: id) {
        continuation.resume(throwing: VoiceyJSONLWorkerError.timeout)
      }
    }
    timeoutWorkItems[id] = work
    queue.asyncAfter(deadline: .now() + seconds, execute: work)
  }

  private func cancelTimeout(for id: String) {
    timeoutWorkItems.removeValue(forKey: id)?.cancel()
  }

  private func cancelAllTimeouts() {
    for work in timeoutWorkItems.values { work.cancel() }
    timeoutWorkItems.removeAll()
  }

  private func failAllPending(_ error: Error) {
    cancelAllTimeouts()
    let continuations = pending.values
    pending.removeAll()
    for continuation in continuations {
      continuation.resume(throwing: error)
    }
  }

  private func consumeStdout(_ chunk: String) {
    stdoutBuffer += chunk
    while let newlineIndex = stdoutBuffer.firstIndex(of: "\n") {
      let line = String(stdoutBuffer[..<newlineIndex])
      stdoutBuffer = String(stdoutBuffer[stdoutBuffer.index(after: newlineIndex)...])
      parseLine(line.trimmingCharacters(in: .whitespacesAndNewlines))
    }
  }

  private func parseLine(_ line: String) {
    guard !line.isEmpty,
      let data = line.data(using: .utf8),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let id = json["id"] as? String,
      let continuation = pending.removeValue(forKey: id)
    else { return }

    cancelTimeout(for: id)
    continuation.resume(returning: json)
  }
}

enum VoiceyJSONLWorkerError: LocalizedError {
  case serializationFailed
  case notRunning
  case timeout
  case workerFailed(String)

  var errorDescription: String? {
    switch self {
    case .serializationFailed: return "Unable to serialize worker request"
    case .notRunning: return "Worker process is not running"
    case .timeout: return "Worker request timed out"
    case .workerFailed(let message): return message
    }
  }
}

enum VoiceyJSONLResponse {
  static func ensureSuccess(_ json: [String: Any], context: String) throws {
    let type = json["type"] as? String ?? ""
    switch type {
    case "pong", "ready", "infer_ready", "capture_ready", "ok", "capture_level":
      return
    case "transcribe_result":
      if (json["ok"] as? Bool) == true { return }
      throw VoiceyJSONLWorkerError.workerFailed(json["error"] as? String ?? context)
    case "capture_fixture_result":
      if (json["ok"] as? Bool) == true { return }
      throw VoiceyJSONLWorkerError.workerFailed(json["error"] as? String ?? context)
    case "error":
      throw VoiceyJSONLWorkerError.workerFailed(json["message"] as? String ?? context)
    default:
      if (json["ok"] as? Bool) == false {
        throw VoiceyJSONLWorkerError.workerFailed(json["error"] as? String ?? context)
      }
    }
  }
}
