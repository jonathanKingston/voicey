import Foundation
import os
import Darwin
import VoiceyCore

/// Engine for IBM Granite Speech models using Python mlx-audio for inference on Apple Silicon.
///
/// Used by benchmark CLI tooling only (`BenchmarkSpeechBackend`). The production app uses Qwen.
final class GraniteEngine: @unchecked Sendable {
  private var isLoading = false
  private var modelReady = false
  private var modelPath: String?

  /// Callback to notify when model loading state changes
  var onLoadingStateChanged: ((Bool) -> Void)?

  /// Callback when performance issues are detected
  var onPerformanceIssue: ((PerformanceMetrics) -> Void)?

  /// Rolling average of real-time factors for recent transcriptions
  private var recentRTFs: [Double] = []
  private let maxRTFHistory = 5
  private var dependenciesReady = false
  private let worker = GranitePythonWorker()
  private static let requiredPythonModules = [
    ("mlx_audio", "mlx-audio"),
    ("huggingface_hub", "huggingface_hub"),
    ("numpy", "numpy")
  ]

  /// Average RTF over recent transcriptions
  var averageRTF: Double {
    guard !recentRTFs.isEmpty else { return 0 }
    return recentRTFs.reduce(0, +) / Double(recentRTFs.count)
  }

  /// Whether recent transcriptions indicate the system is struggling
  var isSystemStruggling: Bool {
    guard recentRTFs.count >= 2 else { return false }
    return averageRTF > 1.5
  }

  init() {}

  deinit {
    let workerRef = worker
    Task {
      await workerRef.stop()
    }
  }

  /// Check if the model is ready for transcription
  var isModelLoaded: Bool {
    modelReady
  }

  /// Pre-load the Granite model by verifying Python environment and model availability
  func preloadModel() async {
    let selectedModel = SettingsManager.shared.selectedModel
    guard selectedModel.isGraniteModel else { return }

    if modelReady {
      return
    }

    if isLoading {
      while isLoading {
        try? await Task.sleep(nanoseconds: 100_000_000)
      }
      if modelReady {
        return
      }
    }

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

    // Check if model is downloaded
    guard let path = ModelManager.shared.modelPath(for: selectedModel) else {
      AppLogger.model.error("GraniteEngine: Model not downloaded")
      return
    }

    modelPath = path

    do {
      try await ensurePythonDependencies()
      try await worker.start(modelPath: path, environment: pythonEnvironment())
      modelReady = true
      debugPrint("✅ GraniteEngine: Granite worker ready", category: "MODEL")
      AppLogger.model.info("GraniteEngine: Model ready at \(path)")
    } catch {
      AppLogger.model.error("GraniteEngine: Failed to verify Python environment: \(error)")
      debugPrint(
        "❌ GraniteEngine: Missing Granite Python dependencies. Bundle or install them before using Granite.",
        category: "MODEL"
      )
    }
  }

  /// Unload the model
  func unloadModel() {
    modelReady = false
    modelPath = nil
    dependenciesReady = false
    Task {
      await worker.stop()
    }
  }

  /// Load a specific model variant
  func loadModel(variant: String) async throws {
    guard let model = SpeechModel(rawValue: variant), model.isGraniteModel else {
      throw GraniteError.invalidModel
    }

    guard let path = ModelManager.shared.modelPath(for: model) else {
      throw GraniteError.modelNotDownloaded
    }

    try await ensurePythonDependencies()
    try await worker.start(modelPath: path, environment: pythonEnvironment())
    modelPath = path
    modelReady = true
  }

  /// Transcribe audio samples (16kHz mono float32) using Granite Speech via Python
  func transcribe(audioBuffer: [Float]) async throws -> TranscriptionResult {
    guard modelReady else {
      throw GraniteError.modelNotReady
    }

    let selectedModel = SettingsManager.shared.selectedModel
    guard selectedModel.isGraniteModel else {
      throw GraniteError.invalidModel
    }

    // Calculate audio duration (16kHz sample rate)
    let audioDuration = Double(audioBuffer.count) / 16000.0
    let thermalStateBefore = ProcessInfo.processInfo.thermalState

    // Granite is more hallucination-prone on very low-level inputs. For quiet
    // speech we normalize up to a bounded RMS target; near-silence returns empty.
    let (conditionedAudio, inputRMS, appliedGain) = conditionAudioForInference(audioBuffer)
    if conditionedAudio.isEmpty {
      AppLogger.transcription.info(
        "GraniteEngine: Input RMS \(String(format: "%.5f", inputRMS)) below floor; returning empty transcription to avoid low-audio hallucination"
      )

      let metrics = PerformanceMetrics(
        realTimeFactor: 0,
        audioDuration: audioDuration,
        processingTime: 0,
        thermalState: thermalStateBefore
      )

      return TranscriptionResult(
        text: "",
        segments: [],
        language: "en",
        processingTime: 0,
        performanceMetrics: metrics
      )
    }

    if appliedGain > 1 {
      AppLogger.transcription.info(
        "GraniteEngine: Boosted low-level input by \(String(format: "%.2f", appliedGain))x (RMS \(String(format: "%.5f", inputRMS)) -> \(String(format: "%.5f", inputRMS * appliedGain)))"
      )
    }

    // Always use the locally downloaded model path.
    guard let localModelPath = modelPath ?? ModelManager.shared.modelPath(for: selectedModel) else {
      throw GraniteError.modelNotDownloaded
    }

    // Ensure worker is available (it may have been terminated externally).
    try await worker.start(modelPath: localModelPath, environment: pythonEnvironment())

    AppLogger.transcription.info(
      "GraniteEngine: Starting transcription of \(conditionedAudio.count) samples (~\(String(format: "%.1f", audioDuration))s)"
    )

    let startTime = CFAbsoluteTimeGetCurrent()

    // Write audio to temp file as raw float32
    let tempDir = FileManager.default.temporaryDirectory
    let audioFile = tempDir.appendingPathComponent("voicey_audio_\(UUID().uuidString).raw")

    let audioData = conditionedAudio.withUnsafeBufferPointer { bufferPointer in
      Data(buffer: bufferPointer)
    }
    try audioData.write(to: audioFile)
    defer { try? FileManager.default.removeItem(at: audioFile) }

    let output = try await worker.transcribe(
      audioPath: audioFile.path,
      sampleRate: 16000,
      maxTokens: 1024,
      timeout: 120
    )
    let processingTime = CFAbsoluteTimeGetCurrent() - startTime

    let transcribedText = output.trimmingCharacters(in: .whitespacesAndNewlines)

    // Calculate performance metrics
    let rtf = audioDuration > 0 ? processingTime / audioDuration : 0
    let metrics = PerformanceMetrics(
      realTimeFactor: rtf,
      audioDuration: audioDuration,
      processingTime: processingTime,
      thermalState: thermalStateBefore
    )

    // Track RTF history
    recentRTFs.append(rtf)
    if recentRTFs.count > maxRTFHistory {
      recentRTFs.removeFirst()
    }

    AppLogger.transcription.info(
      "GraniteEngine: Transcription completed in \(String(format: "%.2f", processingTime))s (RTF: \(String(format: "%.2f", rtf)))"
    )

    debugPrint("📊 Performance: \(metrics.description)", category: "PERF")

    if metrics.isStruggling {
      await MainActor.run {
        onPerformanceIssue?(metrics)
      }
    }

    return TranscriptionResult(
      text: transcribedText,
      segments: [],
      language: "en",
      processingTime: processingTime,
      performanceMetrics: metrics
    )
  }

  private func conditionAudioForInference(_ samples: [Float]) -> (samples: [Float], rms: Float, gain: Float) {
    let result = InferenceAudioConditioning.conditionForInference(samples)
    return (result.samples, result.inputRMS, result.appliedGain)
  }

  private func calculateRMS(_ samples: [Float]) -> Float {
    InferenceAudioConditioning.calculateRMS(samples)
  }

  /// Reset performance tracking
  func resetPerformanceTracking() {
    recentRTFs.removeAll()
  }

  // MARK: - Python Execution

  private func pythonEnvironment() -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    let extraPaths = [
      "/opt/homebrew/bin",
      "/usr/local/bin",
      "/usr/bin"
    ]
    if let existingPath = env["PATH"] {
      env["PATH"] = extraPaths.joined(separator: ":") + ":" + existingPath
    } else {
      env["PATH"] = extraPaths.joined(separator: ":")
    }
    return env
  }

  /// Ensure the required Python packages are already available.
  /// Runtime package installation stays disabled so Granite does not add PyPI egress.
  private func ensurePythonDependencies() async throws {
    if dependenciesReady { return }

    let bootstrapScript = """
      import importlib.util

      required = [\(Self.requiredPythonModules.map { "[\"\($0.0)\", \"\($0.1)\"]" }.joined(separator: ", "))]

      missing = [pip_name for module_name, pip_name in required if importlib.util.find_spec(module_name) is None]

      if missing:
          raise RuntimeError("Missing Granite Python dependencies: " + ", ".join(missing))

      print("OK")
      """

    let output = try await runPython(script: bootstrapScript, timeout: 300)
    guard output.contains("OK") else {
      throw GraniteError.pythonError("Dependency setup did not complete successfully")
    }

    dependenciesReady = true
  }

  /// Run a Python script and return its stdout output
  private func runPython(script: String, timeout: TimeInterval) async throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["python3", "-c", script]

    process.environment = pythonEnvironment()

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    let outputBuffer = PythonOutputBuffer()
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

        AppLogger.transcription.error("GraniteEngine Python error: \(errorOutput)")
        throw GraniteError.pythonError(errorOutput)
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

        throw GraniteError.pythonTimedOut(timeout)
      }

      let firstResult = try await group.next() ?? ""
      group.cancelAll()
      return firstResult
    }
  }
}

private actor GranitePythonWorker {
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
    env["VOICEY_GRANITE_MODEL_PATH"] = modelPath
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

    let deadline = Date().addingTimeInterval(120)
    while Date() < deadline {
      if isReady {
        return
      }
      if !(self.process?.isRunning ?? false) {
        let reason = stderrBuffer.isEmpty ? "Granite worker exited during startup" : stderrBuffer
        throw GraniteError.pythonError(reason)
      }
      try? await Task.sleep(nanoseconds: 100_000_000)
    }

    throw GraniteError.pythonTimedOut(120)
  }

  func transcribe(audioPath: String, sampleRate: Int, maxTokens: Int, timeout: TimeInterval) async throws
    -> String {
    guard let process, process.isRunning, let stdinHandle else {
      throw GraniteError.pythonError("Granite worker not running")
    }

    let requestID = UUID().uuidString
    let request: [String: Any] = [
      "type": "transcribe",
      "id": requestID,
      "audio_path": audioPath,
      "sample_rate": sampleRate,
      "max_tokens": maxTokens,
      "language": "en"
    ]

    let requestData = try JSONSerialization.data(withJSONObject: request)
    guard var requestLine = String(data: requestData, encoding: .utf8) else {
      throw GraniteError.pythonError("Failed to serialize worker request")
    }
    requestLine += "\n"
    guard let lineData = requestLine.data(using: .utf8) else {
      throw GraniteError.pythonError("Failed to encode worker request")
    }
    stdinHandle.write(lineData)

    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if let response = responses.removeValue(forKey: requestID) {
        if response.ok {
          return response.text ?? ""
        }
        throw GraniteError.pythonError(response.error ?? "Unknown Granite worker error")
      }
      if !(self.process?.isRunning ?? false) {
        let reason = stderrBuffer.isEmpty ? "Granite worker exited during transcription" : stderrBuffer
        throw GraniteError.pythonError(reason)
      }
      try? await Task.sleep(nanoseconds: 20_000_000)
    }

    throw GraniteError.pythonTimedOut(timeout)
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
      let line = String(stdoutBuffer[..<newlineIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
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
import numpy as np
from mlx_audio import stt

MODEL_PATH = os.environ.get("VOICEY_GRANITE_MODEL_PATH")
if not MODEL_PATH:
    print(json.dumps({"event":"fatal","error":"VOICEY_GRANITE_MODEL_PATH not set"}), flush=True)
    sys.exit(1)

model = stt.load_model(MODEL_PATH)
print(json.dumps({"event":"ready"}), flush=True)

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
        sample_rate = int(req.get("sample_rate", 16000))
        max_tokens = int(req.get("max_tokens", 1024))
        language = req.get("language", "en")
        audio = np.fromfile(audio_path, dtype=np.float32)

        result = model.generate(
            audio,
            language=language,
            max_tokens=max_tokens,
            verbose=False,
            sample_rate=sample_rate,
        )

        if isinstance(result, dict):
            text = result.get("text", "")
        elif isinstance(result, str):
            text = result
        elif hasattr(result, "text"):
            text = result.text
        else:
            text = str(result)

        print(json.dumps({"id": req_id, "ok": True, "text": text.strip()}), flush=True)
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

private actor PythonOutputBuffer {
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

// MARK: - Errors

enum GraniteError: LocalizedError {
  case modelNotReady
  case modelNotDownloaded
  case invalidModel
  case pythonError(String)
  case pythonNotFound
  case pythonTimedOut(TimeInterval)

  var errorDescription: String? {
    switch self {
    case .modelNotReady:
      return "Granite Speech model is not loaded"
    case .modelNotDownloaded:
      return "Granite Speech model is not downloaded"
    case .invalidModel:
      return "Invalid Granite model variant"
    case .pythonError(let message):
      return "Python error: \(message)"
    case .pythonNotFound:
      return "Python 3 not found. Install Python 3 and the Granite dependencies before selecting Granite."
    case .pythonTimedOut(let seconds):
      return "Python transcription timed out after \(Int(seconds))s"
    }
  }
}
