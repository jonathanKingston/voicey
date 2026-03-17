import Foundation
import os
import Darwin

/// Engine for IBM Granite Speech models using Python mlx-audio for inference on Apple Silicon
final class GraniteEngine {
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

  /// Check if the model is ready for transcription
  var isModelLoaded: Bool {
    modelReady
  }

  /// Pre-load the Granite model by verifying Python environment and model availability
  func preloadModel() async {
    guard !isLoading && !modelReady else { return }

    let selectedModel = SettingsManager.shared.selectedModel
    guard selectedModel.isGraniteModel else { return }

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

    // Verify Python and mlx-audio are available
    let checkScript = """
      import mlx_audio
      print("OK")
      """

    do {
      let output = try await runPython(script: checkScript, timeout: 30)
      if output.contains("OK") {
        modelReady = true
        debugPrint("✅ GraniteEngine: Python environment verified, model ready", category: "MODEL")
        AppLogger.model.info("GraniteEngine: Model ready at \(path)")
      } else {
        AppLogger.model.error("GraniteEngine: Python environment check failed")
      }
    } catch {
      AppLogger.model.error("GraniteEngine: Failed to verify Python environment: \(error)")
      debugPrint("❌ GraniteEngine: Python/mlx-audio not available. Install with: pip3 install mlx-audio", category: "MODEL")
    }
  }

  /// Unload the model
  func unloadModel() {
    modelReady = false
    modelPath = nil
  }

  /// Load a specific model variant
  func loadModel(variant: String) async throws {
    guard let model = SpeechModel(rawValue: variant), model.isGraniteModel else {
      throw GraniteError.invalidModel
    }

    guard let path = ModelManager.shared.modelPath(for: model) else {
      throw GraniteError.modelNotDownloaded
    }

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

    // Always use the locally downloaded model path.
    guard let localModelPath = modelPath ?? ModelManager.shared.modelPath(for: selectedModel) else {
      throw GraniteError.modelNotDownloaded
    }

    // Calculate audio duration (16kHz sample rate)
    let audioDuration = Double(audioBuffer.count) / 16000.0
    let thermalStateBefore = ProcessInfo.processInfo.thermalState

    AppLogger.transcription.info(
      "GraniteEngine: Starting transcription of \(audioBuffer.count) samples (~\(String(format: "%.1f", audioDuration))s)"
    )

    let startTime = CFAbsoluteTimeGetCurrent()

    // Write audio to temp file as raw float32
    let tempDir = FileManager.default.temporaryDirectory
    let audioFile = tempDir.appendingPathComponent("voicey_audio_\(UUID().uuidString).raw")

    let audioData = audioBuffer.withUnsafeBufferPointer { bufferPointer in
      Data(buffer: bufferPointer)
    }
    try audioData.write(to: audioFile)
    defer { try? FileManager.default.removeItem(at: audioFile) }

    // Python script that reads raw audio and transcribes using mlx-audio
    let transcribeScript = """
      import sys
      import numpy as np
      import mlx_audio

      # Read raw float32 audio
      audio_data = np.fromfile("\(audioFile.path)", dtype=np.float32)

      # Transcribe using mlx-audio STT
      result = mlx_audio.stt.generate(
          model=r"\(localModelPath)",
          audio=audio_data,
          sample_rate=16000
      )

      # Output the transcription text
      if isinstance(result, dict):
          text = result.get("text", "")
      elif isinstance(result, str):
          text = result
      else:
          text = str(result)

      print(text.strip())
      """

    let output = try await runPython(script: transcribeScript, timeout: 120)
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

  /// Reset performance tracking
  func resetPerformanceTracking() {
    recentRTFs.removeAll()
  }

  // MARK: - Python Execution

  /// Run a Python script and return its stdout output
  private func runPython(script: String, timeout: TimeInterval) async throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["python3", "-c", script]

    // Inherit PATH so user's Python environment is found
    var env = ProcessInfo.processInfo.environment
    // Add common Python install paths
    let extraPaths = [
      "/opt/homebrew/bin",
      "/usr/local/bin",
      "\(NSHomeDirectory())/.local/bin",
      "\(NSHomeDirectory())/Library/Python/3.11/bin",
      "\(NSHomeDirectory())/Library/Python/3.12/bin",
    ]
    if let existingPath = env["PATH"] {
      env["PATH"] = extraPaths.joined(separator: ":") + ":" + existingPath
    }
    process.environment = env

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    try process.run()
    let timeoutNanoseconds = UInt64(timeout * 1_000_000_000)

    return try await withThrowingTaskGroup(of: String.self) { group in
      group.addTask {
        process.waitUntilExit()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8) ?? ""
        let errorOutput = String(data: errorData, encoding: .utf8) ?? ""

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
      return "Python 3 not found. Install Python 3 and mlx-audio (pip3 install mlx-audio)"
    case .pythonTimedOut(let seconds):
      return "Python transcription timed out after \(Int(seconds))s"
    }
  }
}
