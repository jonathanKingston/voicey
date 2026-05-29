import Foundation

/// JSONL IPC types shared with `voicey-protocol` (Rust). Keep in sync with `crates/voicey-protocol/fixtures/`.
public enum VoiceyProtocol {
  public static let version: UInt32 = 1
}

// MARK: - Runtime kind

public enum VoiceyRuntimeKind: String, Codable, Equatable {
  case inProcess = "in_process"
  case multiprocess
}

// MARK: - Host ↔ supervisor

public enum VoiceyHostRequest: Equatable {
  case ping(id: String)
  case prewarmAllWorkers(id: String, modelID: String)
  case prewarmInfer(id: String, modelID: String)
  case prewarmCapture(id: String)
  case loadModel(id: String, modelID: String)
  case unloadModel(id: String)
  case transcribe(
    id: String,
    modelID: String,
    sampleRate: UInt32,
    shmName: String,
    sampleCount: Int,
    sampleOffset: Int,
    decoderContext: String?
  )
  case downloadModel(id: String, modelID: String, destinationRoot: String)
  case cancelDownload(id: String, modelID: String)
  case startCapture(id: String)
  case stopCapture(id: String)
  case captureFixture(id: String, durationSeconds: Double)
}

extension VoiceyHostRequest: Codable {
  private enum CodingKeys: String, CodingKey {
    case type
    case id
    case modelID = "model_id"
    case sampleRate = "sample_rate"
    case shmName = "shm_name"
    case sampleCount = "sample_count"
    case sampleOffset = "sample_offset"
    case decoderContext = "decoder_context"
    case destinationRoot = "destination_root"
    case durationSeconds = "duration_seconds"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let type = try container.decode(String.self, forKey: .type)
    switch type {
    case "ping":
      self = .ping(id: try container.decode(String.self, forKey: .id))
    case "prewarm_all_workers":
      self = .prewarmAllWorkers(
        id: try container.decode(String.self, forKey: .id),
        modelID: try container.decode(String.self, forKey: .modelID)
      )
    case "prewarm_infer":
      self = .prewarmInfer(
        id: try container.decode(String.self, forKey: .id),
        modelID: try container.decode(String.self, forKey: .modelID)
      )
    case "prewarm_capture":
      self = .prewarmCapture(id: try container.decode(String.self, forKey: .id))
    case "load_model":
      self = .loadModel(
        id: try container.decode(String.self, forKey: .id),
        modelID: try container.decode(String.self, forKey: .modelID)
      )
    case "unload_model":
      self = .unloadModel(id: try container.decode(String.self, forKey: .id))
    case "transcribe":
      self = .transcribe(
        id: try container.decode(String.self, forKey: .id),
        modelID: try container.decode(String.self, forKey: .modelID),
        sampleRate: try container.decode(UInt32.self, forKey: .sampleRate),
        shmName: try container.decode(String.self, forKey: .shmName),
        sampleCount: try container.decode(Int.self, forKey: .sampleCount),
        sampleOffset: try container.decodeIfPresent(Int.self, forKey: .sampleOffset) ?? 0,
        decoderContext: try container.decodeIfPresent(String.self, forKey: .decoderContext)
      )
    case "download_model":
      self = .downloadModel(
        id: try container.decode(String.self, forKey: .id),
        modelID: try container.decode(String.self, forKey: .modelID),
        destinationRoot: try container.decode(String.self, forKey: .destinationRoot)
      )
    case "cancel_download":
      self = .cancelDownload(
        id: try container.decode(String.self, forKey: .id),
        modelID: try container.decode(String.self, forKey: .modelID)
      )
    case "start_capture":
      self = .startCapture(id: try container.decode(String.self, forKey: .id))
    case "stop_capture":
      self = .stopCapture(id: try container.decode(String.self, forKey: .id))
    case "capture_fixture":
      self = .captureFixture(
        id: try container.decode(String.self, forKey: .id),
        durationSeconds: try container.decode(Double.self, forKey: .durationSeconds)
      )
    default:
      throw DecodingError.dataCorruptedError(
        forKey: .type,
        in: container,
        debugDescription: "unknown host request type: \(type)"
      )
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .ping(let id):
      try container.encode("ping", forKey: .type)
      try container.encode(id, forKey: .id)
    case .prewarmAllWorkers(let id, let modelID):
      try container.encode("prewarm_all_workers", forKey: .type)
      try container.encode(id, forKey: .id)
      try container.encode(modelID, forKey: .modelID)
    case .prewarmInfer(let id, let modelID):
      try container.encode("prewarm_infer", forKey: .type)
      try container.encode(id, forKey: .id)
      try container.encode(modelID, forKey: .modelID)
    case .prewarmCapture(let id):
      try container.encode("prewarm_capture", forKey: .type)
      try container.encode(id, forKey: .id)
    case .loadModel(let id, let modelID):
      try container.encode("load_model", forKey: .type)
      try container.encode(id, forKey: .id)
      try container.encode(modelID, forKey: .modelID)
    case .unloadModel(let id):
      try container.encode("unload_model", forKey: .type)
      try container.encode(id, forKey: .id)
    case .transcribe(
      let id, let modelID, let sampleRate, let shmName, let sampleCount, let sampleOffset, let decoderContext):
      try container.encode("transcribe", forKey: .type)
      try container.encode(id, forKey: .id)
      try container.encode(modelID, forKey: .modelID)
      try container.encode(sampleRate, forKey: .sampleRate)
      try container.encode(shmName, forKey: .shmName)
      try container.encode(sampleCount, forKey: .sampleCount)
      try container.encode(sampleOffset, forKey: .sampleOffset)
      try container.encodeIfPresent(decoderContext, forKey: .decoderContext)
    case .downloadModel(let id, let modelID, let destinationRoot):
      try container.encode("download_model", forKey: .type)
      try container.encode(id, forKey: .id)
      try container.encode(modelID, forKey: .modelID)
      try container.encode(destinationRoot, forKey: .destinationRoot)
    case .cancelDownload(let id, let modelID):
      try container.encode("cancel_download", forKey: .type)
      try container.encode(id, forKey: .id)
      try container.encode(modelID, forKey: .modelID)
    case .startCapture(let id):
      try container.encode("start_capture", forKey: .type)
      try container.encode(id, forKey: .id)
    case .stopCapture(let id):
      try container.encode("stop_capture", forKey: .type)
      try container.encode(id, forKey: .id)
    case .captureFixture(let id, let durationSeconds):
      try container.encode("capture_fixture", forKey: .type)
      try container.encode(id, forKey: .id)
      try container.encode(durationSeconds, forKey: .durationSeconds)
    }
  }
}

public enum VoiceyHostResponse: Equatable {
  case pong(id: String)
  case ready(id: String)
  case inferReady(id: String, modelID: String)
  case captureReady(id: String)
  case transcribeResult(
    id: String,
    ok: Bool,
    rawText: String?,
    language: String?,
    processingSeconds: Double?,
    audioSeconds: Double?,
    error: String?
  )
  case downloadProgress(id: String, modelID: String, progress: Double)
  case downloadComplete(id: String, modelID: String, path: String)
  case downloadFailed(id: String, modelID: String, error: String)
  case captureStopped(id: String, shmName: String, sampleCount: Int, sampleRate: UInt32)
  case captureFixtureResult(
    id: String,
    ok: Bool,
    shmName: String?,
    sampleCount: Int?,
    error: String?
  )
  case error(id: String, message: String)
}

extension VoiceyHostResponse: Codable {
  private enum CodingKeys: String, CodingKey {
    case type
    case id
    case modelID = "model_id"
    case ok
    case rawText = "raw_text"
    case language
    case processingSeconds = "processing_seconds"
    case audioSeconds = "audio_seconds"
    case error
    case progress
    case path
    case shmName = "shm_name"
    case sampleCount = "sample_count"
    case sampleRate = "sample_rate"
    case message
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let type = try container.decode(String.self, forKey: .type)
    switch type {
    case "pong":
      self = .pong(id: try container.decode(String.self, forKey: .id))
    case "ready":
      self = .ready(id: try container.decode(String.self, forKey: .id))
    case "infer_ready":
      self = .inferReady(
        id: try container.decode(String.self, forKey: .id),
        modelID: try container.decode(String.self, forKey: .modelID)
      )
    case "capture_ready":
      self = .captureReady(id: try container.decode(String.self, forKey: .id))
    case "transcribe_result":
      self = .transcribeResult(
        id: try container.decode(String.self, forKey: .id),
        ok: try container.decode(Bool.self, forKey: .ok),
        rawText: try container.decodeIfPresent(String.self, forKey: .rawText),
        language: try container.decodeIfPresent(String.self, forKey: .language),
        processingSeconds: try container.decodeIfPresent(Double.self, forKey: .processingSeconds),
        audioSeconds: try container.decodeIfPresent(Double.self, forKey: .audioSeconds),
        error: try container.decodeIfPresent(String.self, forKey: .error)
      )
    case "download_progress":
      self = .downloadProgress(
        id: try container.decode(String.self, forKey: .id),
        modelID: try container.decode(String.self, forKey: .modelID),
        progress: try container.decode(Double.self, forKey: .progress)
      )
    case "download_complete":
      self = .downloadComplete(
        id: try container.decode(String.self, forKey: .id),
        modelID: try container.decode(String.self, forKey: .modelID),
        path: try container.decode(String.self, forKey: .path)
      )
    case "download_failed":
      self = .downloadFailed(
        id: try container.decode(String.self, forKey: .id),
        modelID: try container.decode(String.self, forKey: .modelID),
        error: try container.decode(String.self, forKey: .error)
      )
    case "capture_stopped":
      self = .captureStopped(
        id: try container.decode(String.self, forKey: .id),
        shmName: try container.decode(String.self, forKey: .shmName),
        sampleCount: try container.decode(Int.self, forKey: .sampleCount),
        sampleRate: try container.decode(UInt32.self, forKey: .sampleRate)
      )
    case "capture_fixture_result":
      self = .captureFixtureResult(
        id: try container.decode(String.self, forKey: .id),
        ok: try container.decode(Bool.self, forKey: .ok),
        shmName: try container.decodeIfPresent(String.self, forKey: .shmName),
        sampleCount: try container.decodeIfPresent(Int.self, forKey: .sampleCount),
        error: try container.decodeIfPresent(String.self, forKey: .error)
      )
    case "error":
      self = .error(
        id: try container.decode(String.self, forKey: .id),
        message: try container.decode(String.self, forKey: .message)
      )
    default:
      throw DecodingError.dataCorruptedError(
        forKey: .type,
        in: container,
        debugDescription: "unknown host response type: \(type)"
      )
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .pong(let id):
      try container.encode("pong", forKey: .type)
      try container.encode(id, forKey: .id)
    case .ready(let id):
      try container.encode("ready", forKey: .type)
      try container.encode(id, forKey: .id)
    case .inferReady(let id, let modelID):
      try container.encode("infer_ready", forKey: .type)
      try container.encode(id, forKey: .id)
      try container.encode(modelID, forKey: .modelID)
    case .captureReady(let id):
      try container.encode("capture_ready", forKey: .type)
      try container.encode(id, forKey: .id)
    case .transcribeResult(
      let id, let ok, let rawText, let language, let processingSeconds, let audioSeconds, let error):
      try container.encode("transcribe_result", forKey: .type)
      try container.encode(id, forKey: .id)
      try container.encode(ok, forKey: .ok)
      try container.encodeIfPresent(rawText, forKey: .rawText)
      try container.encodeIfPresent(language, forKey: .language)
      try container.encodeIfPresent(processingSeconds, forKey: .processingSeconds)
      try container.encodeIfPresent(audioSeconds, forKey: .audioSeconds)
      try container.encodeIfPresent(error, forKey: .error)
    case .downloadProgress(let id, let modelID, let progress):
      try container.encode("download_progress", forKey: .type)
      try container.encode(id, forKey: .id)
      try container.encode(modelID, forKey: .modelID)
      try container.encode(progress, forKey: .progress)
    case .downloadComplete(let id, let modelID, let path):
      try container.encode("download_complete", forKey: .type)
      try container.encode(id, forKey: .id)
      try container.encode(modelID, forKey: .modelID)
      try container.encode(path, forKey: .path)
    case .downloadFailed(let id, let modelID, let error):
      try container.encode("download_failed", forKey: .type)
      try container.encode(id, forKey: .id)
      try container.encode(modelID, forKey: .modelID)
      try container.encode(error, forKey: .error)
    case .captureStopped(let id, let shmName, let sampleCount, let sampleRate):
      try container.encode("capture_stopped", forKey: .type)
      try container.encode(id, forKey: .id)
      try container.encode(shmName, forKey: .shmName)
      try container.encode(sampleCount, forKey: .sampleCount)
      try container.encode(sampleRate, forKey: .sampleRate)
    case .captureFixtureResult(let id, let ok, let shmName, let sampleCount, let error):
      try container.encode("capture_fixture_result", forKey: .type)
      try container.encode(id, forKey: .id)
      try container.encode(ok, forKey: .ok)
      try container.encodeIfPresent(shmName, forKey: .shmName)
      try container.encodeIfPresent(sampleCount, forKey: .sampleCount)
      try container.encodeIfPresent(error, forKey: .error)
    case .error(let id, let message):
      try container.encode("error", forKey: .type)
      try container.encode(id, forKey: .id)
      try container.encode(message, forKey: .message)
    }
  }
}

// MARK: - Supervisor ↔ infer worker

public enum VoiceyInferWorkerRequest: Equatable {
  case ping(id: String)
  case loadModel(id: String, modelID: String)
  case unloadModel(id: String)
  case transcribe(
    id: String,
    modelID: String,
    sampleRate: UInt32,
    shmName: String,
    sampleCount: Int,
    sampleOffset: Int,
    decoderContext: String?
  )
  case shutdown(id: String)
}

extension VoiceyInferWorkerRequest: Codable {
  private enum CodingKeys: String, CodingKey {
    case type
    case id
    case modelID = "model_id"
    case sampleRate = "sample_rate"
    case shmName = "shm_name"
    case sampleCount = "sample_count"
    case sampleOffset = "sample_offset"
    case decoderContext = "decoder_context"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let type = try container.decode(String.self, forKey: .type)
    switch type {
    case "ping":
      self = .ping(id: try container.decode(String.self, forKey: .id))
    case "load_model":
      self = .loadModel(
        id: try container.decode(String.self, forKey: .id),
        modelID: try container.decode(String.self, forKey: .modelID)
      )
    case "unload_model":
      self = .unloadModel(id: try container.decode(String.self, forKey: .id))
    case "transcribe":
      self = .transcribe(
        id: try container.decode(String.self, forKey: .id),
        modelID: try container.decode(String.self, forKey: .modelID),
        sampleRate: try container.decode(UInt32.self, forKey: .sampleRate),
        shmName: try container.decode(String.self, forKey: .shmName),
        sampleCount: try container.decode(Int.self, forKey: .sampleCount),
        sampleOffset: try container.decodeIfPresent(Int.self, forKey: .sampleOffset) ?? 0,
        decoderContext: try container.decodeIfPresent(String.self, forKey: .decoderContext)
      )
    case "shutdown":
      self = .shutdown(id: try container.decode(String.self, forKey: .id))
    default:
      throw DecodingError.dataCorruptedError(
        forKey: .type,
        in: container,
        debugDescription: "unknown infer worker request type: \(type)"
      )
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .ping(let id):
      try container.encode("ping", forKey: .type)
      try container.encode(id, forKey: .id)
    case .loadModel(let id, let modelID):
      try container.encode("load_model", forKey: .type)
      try container.encode(id, forKey: .id)
      try container.encode(modelID, forKey: .modelID)
    case .unloadModel(let id):
      try container.encode("unload_model", forKey: .type)
      try container.encode(id, forKey: .id)
    case .transcribe(
      let id, let modelID, let sampleRate, let shmName, let sampleCount, let sampleOffset, let decoderContext):
      try container.encode("transcribe", forKey: .type)
      try container.encode(id, forKey: .id)
      try container.encode(modelID, forKey: .modelID)
      try container.encode(sampleRate, forKey: .sampleRate)
      try container.encode(shmName, forKey: .shmName)
      try container.encode(sampleCount, forKey: .sampleCount)
      try container.encode(sampleOffset, forKey: .sampleOffset)
      try container.encodeIfPresent(decoderContext, forKey: .decoderContext)
    case .shutdown(let id):
      try container.encode("shutdown", forKey: .type)
      try container.encode(id, forKey: .id)
    }
  }
}

public enum VoiceyInferWorkerResponse: Equatable {
  case pong(id: String)
  case ready(id: String)
  case inferReady(id: String, modelID: String)
  case transcribeResult(
    id: String,
    ok: Bool,
    rawText: String?,
    language: String?,
    processingSeconds: Double?,
    audioSeconds: Double?,
    error: String?
  )
  case error(id: String, message: String)
}

extension VoiceyInferWorkerResponse: Codable {
  private enum CodingKeys: String, CodingKey {
    case type
    case id
    case modelID = "model_id"
    case ok
    case rawText = "raw_text"
    case language
    case processingSeconds = "processing_seconds"
    case audioSeconds = "audio_seconds"
    case error
    case message
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let type = try container.decode(String.self, forKey: .type)
    switch type {
    case "pong":
      self = .pong(id: try container.decode(String.self, forKey: .id))
    case "ready":
      self = .ready(id: try container.decode(String.self, forKey: .id))
    case "infer_ready":
      self = .inferReady(
        id: try container.decode(String.self, forKey: .id),
        modelID: try container.decode(String.self, forKey: .modelID)
      )
    case "transcribe_result":
      self = .transcribeResult(
        id: try container.decode(String.self, forKey: .id),
        ok: try container.decode(Bool.self, forKey: .ok),
        rawText: try container.decodeIfPresent(String.self, forKey: .rawText),
        language: try container.decodeIfPresent(String.self, forKey: .language),
        processingSeconds: try container.decodeIfPresent(Double.self, forKey: .processingSeconds),
        audioSeconds: try container.decodeIfPresent(Double.self, forKey: .audioSeconds),
        error: try container.decodeIfPresent(String.self, forKey: .error)
      )
    case "error":
      self = .error(
        id: try container.decode(String.self, forKey: .id),
        message: try container.decode(String.self, forKey: .message)
      )
    default:
      throw DecodingError.dataCorruptedError(
        forKey: .type,
        in: container,
        debugDescription: "unknown infer worker response type: \(type)"
      )
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .pong(let id):
      try container.encode("pong", forKey: .type)
      try container.encode(id, forKey: .id)
    case .ready(let id):
      try container.encode("ready", forKey: .type)
      try container.encode(id, forKey: .id)
    case .inferReady(let id, let modelID):
      try container.encode("infer_ready", forKey: .type)
      try container.encode(id, forKey: .id)
      try container.encode(modelID, forKey: .modelID)
    case .transcribeResult(
      let id, let ok, let rawText, let language, let processingSeconds, let audioSeconds, let error):
      try container.encode("transcribe_result", forKey: .type)
      try container.encode(id, forKey: .id)
      try container.encode(ok, forKey: .ok)
      try container.encodeIfPresent(rawText, forKey: .rawText)
      try container.encodeIfPresent(language, forKey: .language)
      try container.encodeIfPresent(processingSeconds, forKey: .processingSeconds)
      try container.encodeIfPresent(audioSeconds, forKey: .audioSeconds)
      try container.encodeIfPresent(error, forKey: .error)
    case .error(let id, let message):
      try container.encode("error", forKey: .type)
      try container.encode(id, forKey: .id)
      try container.encode(message, forKey: .message)
    }
  }
}
