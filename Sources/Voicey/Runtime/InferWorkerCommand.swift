import Foundation

enum InferWorkerCommand {
  private static let commandName = "infer-worker"

  static func canHandle(_ arguments: [String]) -> Bool {
    arguments.dropFirst().first == commandName
  }

  static func run() async -> Int {
    let engine = QwenEngine()
    while let line = readLine() {
      await handleLine(line.trimmingCharacters(in: .whitespacesAndNewlines), engine: engine)
    }
    return 0
  }

  @MainActor
  private static func handleLine(_ line: String, engine: QwenEngine) async {
    guard !line.isEmpty,
      let data = line.data(using: .utf8),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let type = json["type"] as? String,
      let id = json["id"] as? String
    else { return }

    switch type {
    case "ping":
      writeResponse(["type": "pong", "id": id])
    case "load_model":
      await handleLoadModel(id: id, json: json, engine: engine)
    case "unload_model":
      engine.unloadModel()
      writeResponse(["type": "infer_ready", "id": id, "model_id": ""])
    case "transcribe":
      await handleTranscribe(id: id, json: json, engine: engine)
    case "shutdown":
      writeResponse(["type": "pong", "id": id])
      exit(0)
    default:
      writeResponse(["type": "error", "id": id, "message": "unknown request type: \(type)"])
    }
  }

  @MainActor
  private static func handleLoadModel(id: String, json: [String: Any], engine: QwenEngine) async {
    guard let modelId = json["model_id"] as? String,
      let model = SpeechModel(rawValue: modelId),
      model.isQwenModel
    else {
      writeResponse(["type": "error", "id": id, "message": "invalid qwen model_id"])
      return
    }
    do {
      try await engine.loadModel(variant: model.rawValue)
      writeResponse(["type": "infer_ready", "id": id, "model_id": model.rawValue])
    } catch {
      writeResponse(["type": "error", "id": id, "message": error.localizedDescription])
    }
  }

  @MainActor
  private static func handleTranscribe(id: String, json: [String: Any], engine: QwenEngine) async {
    guard let modelId = json["model_id"] as? String,
      let model = SpeechModel(rawValue: modelId),
      let shmName = json["shm_name"] as? String,
      let sampleCount = json["sample_count"] as? Int
    else {
      writeResponse([
        "type": "transcribe_result",
        "id": id,
        "ok": false,
        "error": "invalid transcribe request"
      ])
      return
    }

    do {
      if !engine.isModelLoaded {
        try await engine.loadModel(variant: model.rawValue)
      }
      let sampleOffset = json["sample_offset"] as? Int ?? 0
      let samples = try SharedMemoryPCM.read(
        name: shmName,
        sampleCount: sampleCount,
        sampleOffset: sampleOffset
      )
      let decoderContext = json["decoder_context"] as? String
      let language = json["language"] as? String
      let result = try await engine.transcribe(
        audioBuffer: samples,
        decoderContext: decoderContext,
        language: language
      )
      writeResponse([
        "type": "transcribe_result",
        "id": id,
        "ok": true,
        "raw_text": result.text,
        "language": result.language,
        "processing_seconds": result.processingTime,
        "audio_seconds": result.performanceMetrics.audioDuration
      ])
    } catch {
      writeResponse([
        "type": "transcribe_result",
        "id": id,
        "ok": false,
        "error": error.localizedDescription
      ])
    }
  }

  private static func writeResponse(_ payload: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: payload),
      var line = String(data: data, encoding: .utf8)
    else { return }
    line += "\n"
    if let lineData = line.data(using: .utf8) {
      FileHandle.standardOutput.write(lineData)
    }
  }
}
