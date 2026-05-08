import Foundation

extension ModelManager {
  /// Download a Gemma model snapshot for the Python Transformers prototype.
  func downloadGemmaModel(_ model: SpeechModel) {
    guard let hfId = model.huggingFaceModelId else { return }

    isDownloading[model] = true
    downloadProgress[model] = 0
    downloadError = nil

    AppLogger.model.info("Starting Gemma model download: \(model.displayName)")

    let task = Task { @MainActor in
      do {
        guard let modelDir = gemmaModelDirectory(for: model) else {
          throw ModelDownloadError.verificationFailed
        }

        try? FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
        let process = try startGemmaDownloadProcess(modelID: hfId, modelDir: modelDir)
        gemmaDownloadProcesses[model] = process

        await monitorGemmaDownload(process: process, model: model, outputBuffer: process.outputBuffer)
      } catch {
        if !Task.isCancelled {
          let errorMessage = "Failed to start download: \(error.localizedDescription)"
          AppLogger.model.error("Gemma model download failed: \(errorMessage)")
          downloadError = errorMessage
          NotificationManager.shared.showModelDownloadFailed(reason: errorMessage)
        }
        isDownloading[model] = false
        downloadProgress[model] = 0
        downloadTasks[model] = nil
      }
    }

    downloadTasks[model] = task
  }

  private func startGemmaDownloadProcess(
    modelID: String,
    modelDir: URL
  ) throws -> GemmaDownloadProcess {
    let downloadScript = """
      import sys
      import subprocess
      import importlib.util
      try:
          if importlib.util.find_spec("huggingface_hub") is None:
              print("Installing huggingface_hub...", file=sys.stderr)
              subprocess.check_call([sys.executable, "-m", "pip", "install", "--user", "huggingface_hub"])

          from huggingface_hub import snapshot_download
          snapshot_download(
              repo_id="\(modelID)",
              local_dir="\(modelDir.path)",
              local_dir_use_symlinks=False
          )
          with open("\(modelDir.path)/.download_complete", "w") as f:
              f.write("ok")
          print("SUCCESS:\(modelDir.path)")
      except Exception as e:
          print("ERROR:" + str(e), file=sys.stderr)
          sys.exit(1)
      """

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["python3", "-c", downloadScript]

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    let outputBuffer = GemmaDownloadOutputBuffer()
    outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      self?.handleGemmaDownloadOutput(handle: handle, model: modelID, outputBuffer: outputBuffer)
    }
    errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      self?.handleGemmaDownloadError(handle: handle, model: modelID, outputBuffer: outputBuffer)
    }

    try process.run()
    return GemmaDownloadProcess(
      process: process,
      outputPipe: outputPipe,
      errorPipe: errorPipe,
      outputBuffer: outputBuffer
    )
  }

  private func handleGemmaDownloadOutput(
    handle: FileHandle,
    model: String,
    outputBuffer: GemmaDownloadOutputBuffer
  ) {
    let data = handle.availableData
    guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
    Task {
      await outputBuffer.appendStdout(chunk)
    }
    updateGemmaDownloadProgress(from: chunk, modelID: model)
  }

  private func handleGemmaDownloadError(
    handle: FileHandle,
    model: String,
    outputBuffer: GemmaDownloadOutputBuffer
  ) {
    let data = handle.availableData
    guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
    Task {
      await outputBuffer.appendStderr(chunk)
    }
    updateGemmaDownloadProgress(from: chunk, modelID: model)
  }

  private func updateGemmaDownloadProgress(from chunk: String, modelID: String) {
    guard let progress = Self.extractGemmaDownloadProgress(from: chunk),
      let model = SpeechModel.allCases.first(where: { $0.huggingFaceModelId == modelID })
    else {
      return
    }
    Task { @MainActor [weak self] in
      guard self?.isDownloading[model] == true else { return }
      self?.downloadProgress[model] = progress
    }
  }

  private static func extractGemmaDownloadProgress(from text: String) -> Double? {
    let pattern = #"\b(\d{1,3})%\|"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    let matches = regex.matches(in: text, range: range)
    guard let last = matches.last, last.numberOfRanges > 1,
      let percentRange = Range(last.range(at: 1), in: text),
      let percentValue = Int(text[percentRange])
    else {
      return nil
    }

    return Double(min(max(percentValue, 0), 100)) / 100.0
  }

  private func monitorGemmaDownload(
    process: GemmaDownloadProcess,
    model: SpeechModel,
    outputBuffer: GemmaDownloadOutputBuffer
  ) async {
    let modelRef = model
    let managerRef = self

    Task.detached {
      process.process.waitUntilExit()

      process.outputPipe.fileHandleForReading.readabilityHandler = nil
      process.errorPipe.fileHandleForReading.readabilityHandler = nil

      if let finalStdout = String(
        data: process.outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) {
        await outputBuffer.appendStdout(finalStdout)
      }
      if let finalStderr = String(
        data: process.errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) {
        await outputBuffer.appendStderr(finalStderr)
      }

      let exitCode = process.process.terminationStatus
      let (outputLog, errorOutput) = await outputBuffer.snapshot()

      await managerRef.finishGemmaDownload(
        model: modelRef,
        exitCode: exitCode,
        outputLog: outputLog,
        errorOutput: errorOutput
      )
    }
  }

  @MainActor
  private func finishGemmaDownload(
    model: SpeechModel,
    exitCode: Int32,
    outputLog: String,
    errorOutput: String
  ) {
    gemmaDownloadProcesses[model] = nil

    if cancelledDownloads.contains(model) {
      cancelledDownloads.remove(model)
      isDownloading[model] = false
      downloadProgress[model] = 0
      downloadTasks[model] = nil
      return
    }

    if exitCode == 0 && modelPath(for: model) != nil {
      AppLogger.model.info("Gemma model \(model.displayName) downloaded successfully")
      loadDownloadedModels()
      downloadProgress[model] = 1.0
      isDownloading[model] = false
      downloadTasks[model] = nil
      NotificationManager.shared.showModelDownloadComplete(model: model)
      return
    }

    let errorMessage = errorOutput.isEmpty
      ? "Failed to download Gemma model. Ensure Python 3 and huggingface_hub are installed (pip3 install huggingface_hub)."
      : errorOutput
    AppLogger.model.error("Gemma model download failed: \(errorMessage)")
    if !outputLog.isEmpty {
      AppLogger.model.error("Gemma model download output: \(outputLog)")
    }
    downloadError = errorMessage
    isDownloading[model] = false
    downloadProgress[model] = 0
    downloadTasks[model] = nil
    NotificationManager.shared.showModelDownloadFailed(reason: errorMessage)
  }
}

private struct GemmaDownloadProcess {
  let process: Process
  let outputPipe: Pipe
  let errorPipe: Pipe
  let outputBuffer: GemmaDownloadOutputBuffer
}

private actor GemmaDownloadOutputBuffer {
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
