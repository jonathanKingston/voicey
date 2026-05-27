import Foundation
import os

/// JSONL subprocess hosting `QwenEngine` (MLX) for Qwen transcription.
final class QwenInferWorkerClient: @unchecked Sendable {
  private static let defaultRequestTimeoutSeconds: TimeInterval = 120
  private static let loadRequestTimeoutSeconds: TimeInterval = 600
  private static let shutdownRequestTimeoutSeconds: TimeInterval = 5
  private static let maxTranscribeTimeoutSeconds: TimeInterval = 3600

  private static func transcribeTimeoutSeconds(sampleCount: Int) -> TimeInterval {
    let audioDuration = Double(sampleCount) / 16_000.0
    return min(maxTranscribeTimeoutSeconds, max(defaultRequestTimeoutSeconds, audioDuration * 4 + 60))
  }

  private var process: Process?
  private var stdinHandle: FileHandle?
  private var stdoutBuffer = ""
  private var pending: [String: CheckedContinuation<InferWorkerResponsePayload, Error>] = [:]
  private var timeoutWorkItems: [String: DispatchWorkItem] = [:]
  private let queue = DispatchQueue(label: "work.voicey.infer-worker")

  struct InferWorkerResponsePayload {
    let ok: Bool
    let rawText: String?
    let language: String?
    let processingSeconds: Double?
    let audioSeconds: Double?
    let error: String?
  }

  func startIfNeeded() throws {
    if let process, process.isRunning {
      return
    }
    hardStop()

    let process = Process()
    process.executableURL = URL(fileURLWithPath: VoiceyRuntimeConfiguration.inferWorkerPath)
    process.arguments = ["infer-worker"]
    process.environment = ProcessInfo.processInfo.environment

    let inputPipe = Pipe()
    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardInput = inputPipe
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
      self?.queue.async {
        self?.consumeStdout(chunk)
      }
    }

    errorPipe.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
      let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty {
        AppLogger.runtime.debug("Infer worker stderr: \(trimmed, privacy: .public)")
      }
    }

    process.terminationHandler = { [weak self] terminated in
      let status = terminated.terminationStatus
      self?.queue.async {
        VoiceyRuntimeDiagnostics.recordInferWorkerStopped(exitStatus: status)
        self?.failAllPending(
          InferWorkerError.workerExited(status: status)
        )
        self?.process = nil
        self?.stdinHandle = nil
      }
    }

    try process.run()
    self.process = process
    self.stdinHandle = inputPipe.fileHandleForWriting
    AppLogger.runtime.info(
      "Infer worker started pid=\(process.processIdentifier, privacy: .public)"
    )
  }

  func ping() async throws {
    try startIfNeeded()
    _ = try await send(
      request: ["type": "ping", "id": UUID().uuidString],
      timeout: Self.defaultRequestTimeoutSeconds
    )
  }

  func prewarm(model: SpeechModel) async throws {
    try startIfNeeded()
    let response = try await send(
      request: [
        "type": "load_model",
        "id": UUID().uuidString,
        "model_id": model.rawValue
      ],
      timeout: Self.loadRequestTimeoutSeconds
    )
    guard response.ok else {
      let message = response.error ?? "load_model failed"
      VoiceyRuntimeDiagnostics.recordInferWorkerError(message)
      throw InferWorkerError.workerFailed(message)
    }
    VoiceyRuntimeDiagnostics.recordInferWorkerReady(
      model: model,
      processID: process?.processIdentifier
    )
  }

  func transcribe(
    samples: [Float],
    model: SpeechModel,
    decoderContext: String? = nil
  ) async throws -> TranscriptionResult {
    try startIfNeeded()
    let shmName = try SharedMemoryPCM.write(samples: samples)
    defer { SharedMemoryPCM.remove(name: shmName) }

    var request: [String: Any] = [
      "type": "transcribe",
      "id": UUID().uuidString,
      "model_id": model.rawValue,
      "sample_rate": 16_000,
      "shm_name": shmName,
      "sample_count": samples.count
    ]
    if let decoderContext, !decoderContext.isEmpty {
      request["decoder_context"] = decoderContext
    }

    let response = try await send(
      request: request,
      timeout: Self.transcribeTimeoutSeconds(sampleCount: samples.count)
    )

    guard response.ok else {
      let message = response.error ?? "unknown infer worker error"
      VoiceyRuntimeDiagnostics.recordInferWorkerError(message)
      throw InferWorkerError.workerFailed(message)
    }

    let rawText = response.rawText ?? ""
    let processingTime = response.processingSeconds ?? 0
    let audioDuration = response.audioSeconds ?? Double(samples.count) / 16_000.0
    let rtf = audioDuration > 0 ? processingTime / audioDuration : 0

    return TranscriptionResult(
      text: rawText.trimmingCharacters(in: .whitespacesAndNewlines),
      segments: [],
      language: response.language ?? "auto",
      processingTime: processingTime,
      performanceMetrics: PerformanceMetrics(
        realTimeFactor: rtf,
        audioDuration: audioDuration,
        processingTime: processingTime,
        thermalState: ProcessInfo.processInfo.thermalState
      )
    )
  }

  func gracefulShutdown() async {
    if process?.isRunning == true {
      _ = try? await send(
        request: ["type": "shutdown", "id": UUID().uuidString],
        timeout: Self.shutdownRequestTimeoutSeconds
      )
    }
    stop()
  }

  func stop() {
    queue.sync {
      hardStop()
    }
  }

  private func hardStop() {
    stdinHandle?.closeFile()
    if let process, process.isRunning {
      process.terminate()
    }
    process = nil
    stdinHandle = nil
    stdoutBuffer = ""
    cancelAllTimeouts()
    failAllPending(InferWorkerError.workerStopped)
  }

  private func send(request: [String: Any], timeout: TimeInterval) async throws
    -> InferWorkerResponsePayload {
    let id = request["id"] as? String ?? UUID().uuidString
    var requestWithID = request
    requestWithID["id"] = id

    let data = try JSONSerialization.data(withJSONObject: requestWithID)
    guard var line = String(data: data, encoding: .utf8) else {
      throw InferWorkerError.serializationFailed
    }
    line += "\n"
    guard let lineData = line.data(using: .utf8) else {
      throw InferWorkerError.serializationFailed
    }

    return try await withCheckedThrowingContinuation { continuation in
      queue.async {
        guard self.stdinHandle != nil, self.process?.isRunning == true else {
          continuation.resume(throwing: InferWorkerError.workerNotRunning)
          return
        }

        self.pending[id] = continuation
        self.scheduleTimeout(for: id, seconds: timeout)
        self.stdinHandle?.write(lineData)
      }
    }
  }

  private func scheduleTimeout(for id: String, seconds: TimeInterval) {
    timeoutWorkItems[id]?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      if let continuation = self.pending.removeValue(forKey: id) {
        self.timeoutWorkItems.removeValue(forKey: id)
        continuation.resume(throwing: InferWorkerError.timeout)
      }
    }
    timeoutWorkItems[id] = work
    queue.asyncAfter(deadline: .now() + seconds, execute: work)
  }

  private func cancelTimeout(for id: String) {
    timeoutWorkItems.removeValue(forKey: id)?.cancel()
  }

  private func cancelAllTimeouts() {
    for work in timeoutWorkItems.values {
      work.cancel()
    }
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
      let id = json["id"] as? String
    else { return }

    let responseType = json["type"] as? String
    let ok: Bool
    switch responseType {
    case "infer_ready", "pong":
      ok = (json["ok"] as? Bool) ?? true
    case "transcribe_result", "error":
      ok = (json["ok"] as? Bool) ?? false
    default:
      ok = (json["ok"] as? Bool) ?? false
    }

    let errorText = json["error"] as? String ?? json["message"] as? String

    let payload = InferWorkerResponsePayload(
      ok: ok,
      rawText: json["raw_text"] as? String ?? json["text"] as? String,
      language: json["language"] as? String,
      processingSeconds: json["processing_seconds"] as? Double,
      audioSeconds: json["audio_seconds"] as? Double,
      error: errorText
    )

    cancelTimeout(for: id)
    if let continuation = pending.removeValue(forKey: id) {
      if ok {
        continuation.resume(returning: payload)
      } else {
        continuation.resume(throwing: InferWorkerError.workerFailed(errorText ?? "infer worker error"))
      }
    }
  }
}

enum InferWorkerError: LocalizedError {
  case serializationFailed
  case workerFailed(String)
  case workerNotRunning
  case workerStopped
  case workerExited(status: Int32)
  case timeout

  var errorDescription: String? {
    switch self {
    case .serializationFailed:
      return "Unable to serialize infer worker request"
    case .workerFailed(let message):
      return message
    case .workerNotRunning:
      return "Transcription helper is not running"
    case .workerStopped:
      return "Transcription helper stopped"
    case .workerExited(let status):
      return "Transcription helper exited (status \(status))"
    case .timeout:
      return "Transcription helper timed out"
    }
  }
}
