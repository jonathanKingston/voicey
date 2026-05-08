import Darwin
import Foundation
import VoiceyCore
import os

/// Prototype backend for Gemma 4 audio ASR through Python Transformers.
final class GemmaEngine: @unchecked Sendable {
  private static let sampleRate = 16_000
  private static let maxAudioChunkDuration: TimeInterval = 30
  private static let maxTokensPerChunk = 512
  private static let transcriptionTimeout: TimeInterval = 180

  private var isLoading = false
  private var modelReady = false
  private var modelPath: String?
  private var dependenciesReady = false
  private let worker = GemmaPythonWorker()

  var onLoadingStateChanged: ((Bool) -> Void)?
  var onPerformanceIssue: ((PerformanceMetrics) -> Void)?

  private var recentRTFs: [Double] = []
  private let maxRTFHistory = 5

  var averageRTF: Double {
    guard !recentRTFs.isEmpty else { return 0 }
    return recentRTFs.reduce(0, +) / Double(recentRTFs.count)
  }

  var isSystemStruggling: Bool {
    guard recentRTFs.count >= 2 else { return false }
    return averageRTF > 1.5
  }

  var isModelLoaded: Bool {
    modelReady
  }

  deinit {
    let workerRef = worker
    Task {
      await workerRef.stop()
    }
  }

  func preloadModel() async {
    guard !isLoading && !modelReady else { return }

    let selectedModel = SettingsManager.shared.selectedModel
    guard selectedModel.isGemmaModel else { return }

    isLoading = true
    await MainActor.run {
      onLoadingStateChanged?(true)
    }

    defer {
      isLoading = false
      Task { @MainActor in
        onLoadingStateChanged?(false)
      }
    }

    do {
      try await loadModel(variant: selectedModel.rawValue)
      AppLogger.model.info("GemmaEngine: Model ready")
    } catch {
      AppLogger.model.error("GemmaEngine: Failed to preload model: \(error)")
    }
  }

  func loadModel(variant: String) async throws {
    guard let model = SpeechModel(rawValue: variant), model.isGemmaModel else {
      throw GemmaError.invalidModel
    }

    guard let path = ModelManager.shared.modelPath(for: model) else {
      throw GemmaError.modelNotDownloaded
    }

    try await ensurePythonDependencies()
    try await worker.start(modelPath: path, environment: pythonEnvironment())
    modelPath = path
    modelReady = true
  }

  func unloadModel() {
    modelReady = false
    modelPath = nil
    dependenciesReady = false
    Task {
      await worker.stop()
    }
  }

  func transcribe(audioBuffer: [Float]) async throws -> TranscriptionResult {
    guard modelReady else {
      throw GemmaError.modelNotReady
    }

    let selectedModel = SettingsManager.shared.selectedModel
    guard selectedModel.isGemmaModel else {
      throw GemmaError.invalidModel
    }

    guard let localModelPath = modelPath ?? ModelManager.shared.modelPath(for: selectedModel) else {
      throw GemmaError.modelNotDownloaded
    }

    try await worker.start(modelPath: localModelPath, environment: pythonEnvironment())

    let audioDuration = Double(audioBuffer.count) / Double(Self.sampleRate)
    let thermalStateBefore = ProcessInfo.processInfo.thermalState
    let chunks = AudioChunker.chunks(
      from: audioBuffer,
      maxDuration: Self.maxAudioChunkDuration,
      sampleRate: Double(Self.sampleRate)
    )

    AppLogger.transcription.info(
      "GemmaEngine: Starting transcription of \(audioBuffer.count) samples in \(chunks.count) chunk(s)"
    )

    let startTime = CFAbsoluteTimeGetCurrent()
    let tempDir = FileManager.default.temporaryDirectory
    var chunkTexts: [String] = []
    chunkTexts.reserveCapacity(chunks.count)

    for (index, chunk) in chunks.enumerated() {
      let audioFile = tempDir.appendingPathComponent("voicey_gemma_\(UUID().uuidString).wav")
      try Self.writeWAV(samples: chunk.samples, to: audioFile)
      defer { try? FileManager.default.removeItem(at: audioFile) }

      AppLogger.transcription.info(
        "GemmaEngine: Transcribing chunk \(index + 1)/\(chunks.count) at \(String(format: "%.1f", chunk.startTime))s"
      )

      let output = try await worker.transcribe(
        audioPath: audioFile.path,
        maxTokens: Self.maxTokensPerChunk,
        timeout: Self.transcriptionTimeout
      )
      let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
      if !text.isEmpty {
        chunkTexts.append(text)
      }
    }

    let processingTime = CFAbsoluteTimeGetCurrent() - startTime
    let rtf = audioDuration > 0 ? processingTime / audioDuration : 0
    let metrics = PerformanceMetrics(
      realTimeFactor: rtf,
      audioDuration: audioDuration,
      processingTime: processingTime,
      thermalState: thermalStateBefore
    )

    recentRTFs.append(rtf)
    if recentRTFs.count > maxRTFHistory {
      recentRTFs.removeFirst()
    }

    if metrics.isStruggling {
      await MainActor.run {
        onPerformanceIssue?(metrics)
      }
    }

    return TranscriptionResult(
      text: chunkTexts.joined(separator: " "),
      segments: [],
      language: "auto",
      processingTime: processingTime,
      performanceMetrics: metrics
    )
  }

  func resetPerformanceTracking() {
    recentRTFs.removeAll()
  }

  private func pythonEnvironment() -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    let extraPaths = [
      "/opt/homebrew/bin",
      "/usr/local/bin",
      "\(NSHomeDirectory())/.local/bin",
      "\(NSHomeDirectory())/Library/Python/3.11/bin",
      "\(NSHomeDirectory())/Library/Python/3.12/bin"
    ]
    if let existingPath = env["PATH"] {
      env["PATH"] = extraPaths.joined(separator: ":") + ":" + existingPath
    } else {
      env["PATH"] = extraPaths.joined(separator: ":")
    }
    return env
  }

  private func ensurePythonDependencies() async throws {
    if dependenciesReady { return }

    let bootstrapScript = """
      import importlib.util
      import subprocess
      import sys

      required = [
          ("transformers", "transformers"),
          ("torch", "torch"),
          ("torchvision", "torchvision"),
          ("librosa", "librosa"),
          ("accelerate", "accelerate"),
      ]

      missing = [pip_name for module_name, pip_name in required if importlib.util.find_spec(module_name) is None]

      if missing:
          print("Installing Python dependencies: " + ", ".join(missing))
          cmd = [
              sys.executable,
              "-m",
              "pip",
              "install",
              "--user",
              "--disable-pip-version-check",
          ] + missing
          subprocess.check_call(cmd)

      for module_name, _ in required:
          if importlib.util.find_spec(module_name) is None:
              raise RuntimeError(f"Missing required Python module after install: {module_name}")

      print("OK")
      """

    let output = try await runPython(script: bootstrapScript, timeout: 600)
    guard output.contains("OK") else {
      throw GemmaError.pythonError("Dependency setup did not complete successfully")
    }

    dependenciesReady = true
  }

  private func runPython(script: String, timeout: TimeInterval) async throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["python3", "-c", script]
    process.environment = pythonEnvironment()

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    let outputBuffer = GemmaPythonOutputBuffer()
    outputPipe.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
      Task {
        await outputBuffer.appendStdout(chunk)
      }
    }
    errorPipe.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
      Task {
        await outputBuffer.appendStderr(chunk)
      }
    }

    try process.run()
    let timeoutNanoseconds = UInt64(timeout * 1_000_000_000)

    return try await withThrowingTaskGroup(of: String.self) { group in
      group.addTask {
        process.waitUntilExit()

        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil

        if let finalStdout = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) {
          await outputBuffer.appendStdout(finalStdout)
        }
        if let finalStderr = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) {
          await outputBuffer.appendStderr(finalStderr)
        }

        let (output, errorOutput) = await outputBuffer.snapshot()
        if process.terminationStatus == 0 {
          return output
        }
        AppLogger.transcription.error("GemmaEngine Python error: \(errorOutput)")
        throw GemmaError.pythonError(errorOutput)
      }

      group.addTask {
        try await Task.sleep(nanoseconds: timeoutNanoseconds)

        if process.isRunning {
          process.terminate()
          try? await Task.sleep(nanoseconds: 200_000_000)
          if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
          }
        }

        throw GemmaError.pythonTimedOut(timeout)
      }

      let firstResult = try await group.next() ?? ""
      group.cancelAll()
      return firstResult
    }
  }

  private static func writeWAV(samples: [Float], to url: URL) throws {
    let clamped = samples.map { Int16((min(max($0, -1), 1) * Float(Int16.max)).rounded()) }
    let dataSize = UInt32(clamped.count * MemoryLayout<Int16>.size)
    let fileSize = UInt32(36) + dataSize
    let byteRate = UInt32(sampleRate * MemoryLayout<Int16>.size)
    let blockAlign = UInt16(MemoryLayout<Int16>.size)

    var data = Data()
    data.append(contentsOf: "RIFF".utf8)
    data.appendLittleEndian(fileSize)
    data.append(contentsOf: "WAVEfmt ".utf8)
    data.appendLittleEndian(UInt32(16))
    data.appendLittleEndian(UInt16(1))
    data.appendLittleEndian(UInt16(1))
    data.appendLittleEndian(UInt32(sampleRate))
    data.appendLittleEndian(byteRate)
    data.appendLittleEndian(blockAlign)
    data.appendLittleEndian(UInt16(16))
    data.append(contentsOf: "data".utf8)
    data.appendLittleEndian(dataSize)
    for sample in clamped {
      data.appendLittleEndian(UInt16(bitPattern: sample))
    }
    try data.write(to: url)
  }
}

extension Data {
  fileprivate mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
    var littleEndianValue = value.littleEndian
    Swift.withUnsafeBytes(of: &littleEndianValue) { bytes in
      append(contentsOf: bytes)
    }
  }
}

private actor GemmaPythonWorker {
  private struct WorkerResponse {
    let ok: Bool
    let text: String?
    let error: String?
  }

  private var process: Process?
  private var stdinHandle: FileHandle?
  private var stdoutBuffer = ""
  private var stderrBuffer = ""
  private var isReady = false
  private var modelPath: String?
  private var responses: [String: WorkerResponse] = [:]

  func start(modelPath: String, environment: [String: String]) async throws {
    if let process, process.isRunning, self.modelPath == modelPath, isReady {
      return
    }

    stop()

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["python3", "-u", "-c", Self.workerScript]

    var env = environment
    env["VOICEY_GEMMA_MODEL_PATH"] = modelPath
    process.environment = env

    let inputPipe = Pipe()
    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardInput = inputPipe
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
      Task {
        await self?.consumeStdout(chunk)
      }
    }

    errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
      Task {
        await self?.consumeStderr(chunk)
      }
    }

    try process.run()

    self.process = process
    self.stdinHandle = inputPipe.fileHandleForWriting
    self.modelPath = modelPath
    self.stdoutBuffer = ""
    self.stderrBuffer = ""
    self.responses.removeAll()
    self.isReady = false

    let deadline = Date().addingTimeInterval(180)
    while Date() < deadline {
      if isReady {
        return
      }
      if !(self.process?.isRunning ?? false) {
        let reason = stderrBuffer.isEmpty ? "Gemma worker exited during startup" : stderrBuffer
        throw GemmaError.pythonError(reason)
      }
      try? await Task.sleep(nanoseconds: 100_000_000)
    }

    throw GemmaError.pythonTimedOut(180)
  }

  func transcribe(audioPath: String, maxTokens: Int, timeout: TimeInterval) async throws -> String {
    guard let process, process.isRunning, let stdinHandle else {
      throw GemmaError.pythonError("Gemma worker not running")
    }

    let requestID = UUID().uuidString
    let request: [String: Any] = [
      "type": "transcribe",
      "id": requestID,
      "audio_path": audioPath,
      "max_tokens": maxTokens
    ]

    let requestData = try JSONSerialization.data(withJSONObject: request)
    guard var requestLine = String(data: requestData, encoding: .utf8) else {
      throw GemmaError.pythonError("Failed to serialize worker request")
    }
    requestLine += "\n"
    guard let lineData = requestLine.data(using: .utf8) else {
      throw GemmaError.pythonError("Failed to encode worker request")
    }
    stdinHandle.write(lineData)

    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if let response = responses.removeValue(forKey: requestID) {
        if response.ok {
          return response.text ?? ""
        }
        throw GemmaError.pythonError(response.error ?? "Unknown Gemma worker error")
      }
      if !(self.process?.isRunning ?? false) {
        let reason =
          stderrBuffer.isEmpty ? "Gemma worker exited during transcription" : stderrBuffer
        throw GemmaError.pythonError(reason)
      }
      try? await Task.sleep(nanoseconds: 20_000_000)
    }

    throw GemmaError.pythonTimedOut(timeout)
  }

  func stop() {
    process?.terminate()
    process = nil
    stdinHandle = nil
    isReady = false
    modelPath = nil
    responses.removeAll()
  }

  private func consumeStdout(_ chunk: String) {
    stdoutBuffer += chunk
    while let newlineIndex = stdoutBuffer.firstIndex(of: "\n") {
      let line = String(stdoutBuffer[..<newlineIndex]).trimmingCharacters(
        in: .whitespacesAndNewlines)
      stdoutBuffer = String(stdoutBuffer[stdoutBuffer.index(after: newlineIndex)...])
      guard !line.isEmpty else { continue }
      parseWorkerLine(line)
    }
  }

  private func consumeStderr(_ chunk: String) {
    stderrBuffer += chunk
    if stderrBuffer.count > 8_000 {
      stderrBuffer = String(stderrBuffer.suffix(8_000))
    }
  }

  private func parseWorkerLine(_ line: String) {
    guard let data = line.data(using: .utf8),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return
    }

    if let event = json["event"] as? String, event == "ready" {
      isReady = true
      return
    }

    guard let id = json["id"] as? String else { return }
    let ok = (json["ok"] as? Bool) ?? false
    let text = json["text"] as? String
    let error = json["error"] as? String
    responses[id] = WorkerResponse(ok: ok, text: text, error: error)
  }

  private static let workerScript = #"""
    import json
    import os
    import sys
    import traceback
    from transformers import AutoProcessor, AutoModelForMultimodalLM

    MODEL_PATH = os.environ.get("VOICEY_GEMMA_MODEL_PATH")
    if not MODEL_PATH:
        print(json.dumps({"event":"fatal","error":"VOICEY_GEMMA_MODEL_PATH not set"}), flush=True)
        sys.exit(1)

    processor = AutoProcessor.from_pretrained(MODEL_PATH)
    model = AutoModelForMultimodalLM.from_pretrained(
        MODEL_PATH,
        dtype="auto",
        device_map="auto",
    )
    print(json.dumps({"event":"ready"}), flush=True)

    PROMPT = """Transcribe the following speech segment in its original language.

    Follow these specific instructions for formatting the answer:
    * Only output the transcription, with no newlines.
    * When transcribing numbers, write the digits, i.e. write 1.7 and not one point seven, and write 3 instead of three.
    """

    def response_text(response):
        parsed = processor.parse_response(response)
        if isinstance(parsed, str):
            return parsed
        if isinstance(parsed, dict):
            for key in ("text", "content", "answer"):
                value = parsed.get(key)
                if isinstance(value, str):
                    return value
            return json.dumps(parsed, ensure_ascii=False)
        return str(parsed)

    for raw_line in sys.stdin:
        line = raw_line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
            req_id = req.get("id", "")
            req_type = req.get("type")
            if req_type != "transcribe":
                print(json.dumps({"id": req_id, "ok": False, "error": f"unknown request type: {req_type}"}), flush=True)
                continue

            audio_path = req["audio_path"]
            max_tokens = int(req.get("max_tokens", 512))
            messages = [
                {
                    "role": "user",
                    "content": [
                        {"type": "audio", "audio": audio_path},
                        {"type": "text", "text": PROMPT},
                    ],
                }
            ]
            inputs = processor.apply_chat_template(
                messages,
                tokenize=True,
                return_dict=True,
                return_tensors="pt",
                add_generation_prompt=True,
            ).to(model.device)
            input_len = inputs["input_ids"].shape[-1]
            outputs = model.generate(**inputs, max_new_tokens=max_tokens)
            response = processor.decode(outputs[0][input_len:], skip_special_tokens=False)
            text = response_text(response)
            print(json.dumps({"id": req_id, "ok": True, "text": " ".join(text.split())}), flush=True)
        except Exception:
            err = traceback.format_exc()
            safe_id = ""
            try:
                if "req_id" in locals():
                    safe_id = req_id
            except Exception:
                safe_id = ""
            print(json.dumps({"id": safe_id, "ok": False, "error": err}), flush=True)
    """#
}

private actor GemmaPythonOutputBuffer {
  private var stdout = ""
  private var stderr = ""

  func appendStdout(_ chunk: String) {
    stdout += chunk
  }

  func appendStderr(_ chunk: String) {
    stderr += chunk
  }

  func snapshot() -> (String, String) {
    (
      stdout.trimmingCharacters(in: .whitespacesAndNewlines),
      stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    )
  }
}

enum GemmaError: LocalizedError {
  case modelNotReady
  case modelNotDownloaded
  case invalidModel
  case pythonError(String)
  case pythonTimedOut(TimeInterval)

  var errorDescription: String? {
    switch self {
    case .modelNotReady:
      return "Gemma model is not loaded"
    case .modelNotDownloaded:
      return "Gemma model is not downloaded"
    case .invalidModel:
      return "Invalid Gemma model variant"
    case .pythonError(let message):
      return "Python error: \(message)"
    case .pythonTimedOut(let seconds):
      return "Python transcription timed out after \(Int(seconds))s"
    }
  }
}
