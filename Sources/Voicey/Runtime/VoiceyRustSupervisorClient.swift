import Foundation

/// Host control plane for `voicey-supervisor` (optional; `VOICEY_USE_RUST_SUPERVISOR=1`).
final class VoiceyRustSupervisorClient: @unchecked Sendable {
  private var process: VoiceyJSONLWorkerProcess?

  private func client() throws -> VoiceyJSONLWorkerProcess {
    if let process { return process }
    guard let path = VoiceyRuntimeConfiguration.rustSupervisorPath else {
      throw VoiceyRustSupervisorError.missingBinary
    }
    let worker = VoiceyJSONLWorkerProcess(
      executablePath: path,
      environment: { VoiceyRuntimeConfiguration.workerProcessEnvironment() }
    )
    process = worker
    return worker
  }

  func ping() async throws {
    let response = try await client().send(request: ["type": "ping", "id": UUID().uuidString])
    try VoiceyJSONLResponse.ensureSuccess(response, context: "supervisor ping")
  }

  func prewarmAllWorkers(model: SpeechModel) async throws {
    let response = try await client().send(
      request: [
        "type": "prewarm_all_workers",
        "id": UUID().uuidString,
        "model_id": model.rawValue
      ],
      timeout: 600
    )
    try VoiceyJSONLResponse.ensureSuccess(response, context: "prewarm_all_workers")
  }

  func prewarmInfer(model: SpeechModel) async throws {
    let response = try await client().send(
      request: [
        "type": "prewarm_infer",
        "id": UUID().uuidString,
        "model_id": model.rawValue
      ],
      timeout: 600
    )
    try VoiceyJSONLResponse.ensureSuccess(response, context: "prewarm_infer")
  }

  func prewarmCapture() async throws {
    let response = try await client().send(
      request: ["type": "prewarm_capture", "id": UUID().uuidString]
    )
    try VoiceyJSONLResponse.ensureSuccess(response, context: "prewarm_capture")
  }

  func transcribe(
    samples: [Float],
    model: SpeechModel,
    decoderContext: String? = nil
  ) async throws -> TranscriptionResult {
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

    let response = try await client().send(request: request)
    try VoiceyJSONLResponse.ensureSuccess(response, context: "transcribe")

    let rawText = response["raw_text"] as? String ?? ""
    let processingTime = response["processing_seconds"] as? Double ?? 0
    let audioDuration = response["audio_seconds"] as? Double ?? Double(samples.count) / 16_000.0
    let rtf = audioDuration > 0 ? processingTime / audioDuration : 0

    return TranscriptionResult(
      text: rawText.trimmingCharacters(in: .whitespacesAndNewlines),
      segments: [],
      language: response["language"] as? String ?? "auto",
      processingTime: processingTime,
      performanceMetrics: PerformanceMetrics(
        realTimeFactor: rtf,
        audioDuration: audioDuration,
        processingTime: processingTime,
        thermalState: ProcessInfo.processInfo.thermalState
      )
    )
  }

  func stop() {
    process?.stop()
    process = nil
  }
}

enum VoiceyRustSupervisorError: LocalizedError {
  case missingBinary

  var errorDescription: String? {
    switch self {
    case .missingBinary:
      return "voicey-supervisor binary not found (run make build-rust)"
    }
  }
}
