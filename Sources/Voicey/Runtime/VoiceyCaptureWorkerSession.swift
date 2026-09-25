import Foundation
import VoiceyCore

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

  func currentInputLevel() async throws -> Float {
    let snapshot = try await currentCaptureLevelSnapshot()
    return snapshot.level
  }

  func currentCaptureLevelSnapshot() async throws -> (level: Float, sampleCount: Int) {
    let response = try await client().send(
      request: ["type": "get_level", "id": UUID().uuidString],
      timeout: 2
    )
    let level: Float
    if let value = response["level"] as? Double {
      level = Float(value)
    } else if let value = response["level"] as? Float {
      level = value
    } else {
      level = 0
    }
    let sampleCount = response["sample_count"] as? Int ?? 0
    return (level, sampleCount)
  }

  /// Copies live capture samples `[startSampleIndex..]` without draining the worker buffer.
  func readCapturedSamples(since startSampleIndex: Int) async throws -> (
    samples: [Float], totalSampleCount: Int
  ) {
    let response = try await client().send(
      request: [
        "type": "read_captured_samples",
        "id": UUID().uuidString,
        "start_sample_index": startSampleIndex
      ],
      timeout: 30
    )
    guard response["type"] as? String == "capture_samples_read" else {
      throw VoiceyCaptureWorkerError.invalidResponse
    }
    guard response["ok"] as? Bool == true else {
      throw VoiceyCaptureWorkerError.failed(
        response["error"] as? String ?? "read_captured_samples failed")
    }
    let samples = Self.parseSampleArray(response["samples"])
    let totalSampleCount = response["sample_count"] as? Int ?? startSampleIndex + samples.count
    return (samples, totalSampleCount)
  }

  func drainHandsFreeUtterance(
    startSampleIndex: Int,
    endSampleIndex: Int,
    applyTrailingTrim: Bool = true
  ) async throws -> PCMBufferHandle {
    let response = try await client().send(
      request: [
        "type": "drain_hands_free_utterance",
        "id": UUID().uuidString,
        "start_sample_index": startSampleIndex,
        "end_sample_index": endSampleIndex,
        "apply_trailing_trim": applyTrailingTrim
      ],
      timeout: 120
    )
    try VoiceyJSONLResponse.ensureSuccess(response, context: "drain_hands_free_utterance")
    guard let shmName = response["shm_name"] as? String,
      let sampleCount = response["sample_count"] as? Int
    else {
      throw VoiceyCaptureWorkerError.invalidResponse
    }
    let sampleRate = response["sample_rate"] as? Int ?? 16_000
    return PCMBufferHandle(shmName: shmName, sampleCount: sampleCount, sampleRate: sampleRate)
  }

  func startRecording(mode: RecordingMode = .manual) async throws {
    let response = try await client().send(
      request: [
        "type": "start_recording",
        "id": UUID().uuidString,
        "mode": mode == .handsFree ? "hands_free" : "manual"
      ]
    )
    try VoiceyJSONLResponse.ensureSuccess(response, context: "start_recording")
  }

  func stopRecording(applyTrailingTrim: Bool = true) async throws -> PCMBufferHandle {
    let response = try await client().send(
      request: [
        "type": "stop_recording",
        "id": UUID().uuidString,
        "apply_trailing_trim": applyTrailingTrim
      ],
      timeout: 120
    )
    try VoiceyJSONLResponse.ensureSuccess(response, context: "stop_recording")
    guard let shmName = response["shm_name"] as? String,
      let sampleCount = response["sample_count"] as? Int
    else {
      throw VoiceyCaptureWorkerError.invalidResponse
    }
    let sampleRate = response["sample_rate"] as? Int ?? 16_000
    return PCMBufferHandle(shmName: shmName, sampleCount: sampleCount, sampleRate: sampleRate)
  }

  func archiveUtterance(
    archiveRoot: URL,
    audio: [String: Any],
    metadata: [String: Any],
    snapshot: UtteranceArchiveScreenSnapshot?,
    maxEntries: Int = SessionArchiveStore.defaultMaxEntries
  ) async throws {
    var request: [String: Any] = [
      "type": "archive_utterance",
      "id": UUID().uuidString,
      "archive_root": archiveRoot.path,
      "max_entries": maxEntries,
      "audio": audio,
      "metadata": metadata
    ]
    if let snapshot {
      request["snapshot"] = [
        "query_text": snapshot.queryText,
        "corpus_chunks": snapshot.corpusChunks
      ]
    }
    let response = try await client().send(request: request, timeout: 120)
    guard response["type"] as? String == "archive_result" else {
      throw VoiceyCaptureWorkerError.invalidResponse
    }
    guard response["ok"] as? Bool == true else {
      throw VoiceyCaptureWorkerError.failed(response["error"] as? String ?? "archive_utterance failed")
    }
  }

  func deleteArchive(archiveRoot: URL) async throws {
    let response = try await client().send(
      request: [
        "type": "delete_archive",
        "id": UUID().uuidString,
        "archive_root": archiveRoot.path
      ],
      timeout: 30
    )
    guard response["type"] as? String == "delete_archive_result" else {
      throw VoiceyCaptureWorkerError.invalidResponse
    }
    guard response["ok"] as? Bool == true else {
      throw VoiceyCaptureWorkerError.failed(response["error"] as? String ?? "delete_archive failed")
    }
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

  func loadWavFile(path: String) async throws -> PCMBufferHandle {
    let response = try await client().send(
      request: [
        "type": "load_wav_file",
        "id": UUID().uuidString,
        "path": path
      ],
      timeout: 120
    )
    try VoiceyJSONLResponse.ensureSuccess(response, context: "load_wav_file")
    guard let shmName = response["shm_name"] as? String,
      let sampleCount = response["sample_count"] as? Int
    else {
      throw VoiceyCaptureWorkerError.invalidResponse
    }
    let sampleRate = response["sample_rate"] as? Int ?? 16_000
    return PCMBufferHandle(shmName: shmName, sampleCount: sampleCount, sampleRate: sampleRate)
  }

  func stop() {
    process?.stop()
    process = nil
  }

  private static func parseSampleArray(_ value: Any?) -> [Float] {
    guard let array = value as? [Any] else { return [] }
    return array.compactMap { element in
      if let sample = element as? Double { return Float(sample) }
      if let sample = element as? Float { return sample }
      if let sample = element as? Int { return Float(sample) }
      return nil
    }
  }
}

extension VoiceyCaptureWorkerError {
  static var missingBinary: VoiceyCaptureWorkerError { .failed("voicey-capture binary not found") }
}
