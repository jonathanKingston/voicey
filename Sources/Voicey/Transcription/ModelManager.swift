import Combine
import AudioCommon
import Foundation
import WhisperKit
import os

/// Available speech model variants
enum SpeechModel: String, CaseIterable, Identifiable {
  // Qwen3 ASR models (native MLX Swift)
  case qwen3Large = "qwen3-asr-1.7b-bf16"
  case qwen3Small = "qwen3-asr-0.6b-6bit"

  // Granite Speech models (IBM)
  case graniteSpeech = "granite-4.0-1b-speech"

  // Whisper models - WhisperKit uses underscores for turbo variants (large-v3_turbo, not large-v3-turbo)
  // Multilingual models (support 99+ languages)
  case largeTurbo = "large-v3_turbo"
  case large = "large-v3"
  case distilLarge = "distil-large-v3"
  case small = "small"
  case base = "base"
  case tiny = "tiny"
  // English-only models (optimized for English, smaller/faster)
  case smallEn = "small.en"
  case baseEn = "base.en"
  case tinyEn = "tiny.en"

  var id: String { rawValue }

  var backendKind: SpeechBackendKind {
    switch self {
    case .graniteSpeech:
      return .granitePython
    case .qwen3Small, .qwen3Large:
      return .qwenMLX
    default:
      return .whisperKit
    }
  }

  /// Whether this model uses the Granite Speech engine (vs WhisperKit)
  var isGraniteModel: Bool {
    backendKind == .granitePython
  }

  /// Whether this model uses WhisperKit for inference
  var isWhisperModel: Bool {
    backendKind == .whisperKit
  }

  /// Whether this model uses native Swift MLX inference
  var isQwenModel: Bool {
    backendKind == .qwenMLX
  }

  /// Whether this model is available in the app UI (Qwen only; other cases remain for benchmarks)
  var isUserFacing: Bool {
    isQwenModel
  }

  /// Legacy Whisper/Granite models kept for benchmark CLI tooling only.
  var isBenchmarkModel: Bool {
    !isUserFacing
  }

  /// Models shown in settings and download UI
  static var userFacingModels: [SpeechModel] {
    [.qwen3Large, .qwen3Small]
  }

  /// Whisper and Granite models used by benchmark commands and parity harnesses.
  static var benchmarkModels: [SpeechModel] {
    allCases.filter(\.isBenchmarkModel)
  }

  var displayName: String {
    switch self {
    case .graniteSpeech: return "Granite 4.0 1B Speech"
    case .qwen3Small: return "Qwen3 ASR 0.6B (MLX)"
    case .qwen3Large: return "Qwen3 ASR 1.7B (MLX)"
    case .largeTurbo: return "Large v3 Turbo"
    case .large: return "Large v3"
    case .distilLarge: return "Distil Large v3"
    case .small: return "Small (Multilingual)"
    case .base: return "Base (Multilingual)"
    case .tiny: return "Tiny (Multilingual)"
    case .smallEn: return "Small (English)"
    case .baseEn: return "Base (English)"
    case .tinyEn: return "Tiny (English)"
    }
  }

  var description: String {
    switch self {
    case .graniteSpeech: return "#1 on OpenASR leaderboard, multilingual, ~1GB (requires Python + mlx-audio)"
    case .qwen3Small:
      return "Native Swift MLX, multilingual auto-detect, fast startup (~400MB)"
    case .qwen3Large:
      return "Native Swift MLX, multilingual auto-detect, highest Qwen quality (~1.7GB)"
    case .largeTurbo: return "Fast & accurate, 8x faster than Large (~1.5GB)"
    case .large: return "Maximum accuracy, slower (~3GB)"
    case .distilLarge: return "Distilled model, fast & accurate (~800MB)"
    case .small: return "Balanced speed/accuracy, multilingual (~250MB)"
    case .base: return "Fast, basic accuracy, multilingual (~80MB)"
    case .tiny: return "Fastest, lowest accuracy, multilingual (~40MB)"
    case .smallEn: return "Balanced speed/accuracy, English only (~250MB)"
    case .baseEn: return "Fast, basic accuracy, English only (~80MB)"
    case .tinyEn: return "Fastest, lowest accuracy, English only (~40MB)"
    }
  }

  var isRecommended: Bool {
    self == .qwen3Large
  }

  /// Whether this model only supports English
  var isEnglishOnly: Bool {
    switch self {
    case .smallEn, .baseEn, .tinyEn: return true
    default: return false
    }
  }

  /// Whether this is a "fast" model suitable for quick startup
  var isFastModel: Bool {
    switch self {
    case .qwen3Small:
      return true
    case .base, .baseEn, .tiny, .tinyEn, .small, .smallEn: return true
    default: return false
    }
  }

  var diskSize: Int64 {
    switch self {
    case .graniteSpeech: return 1_000_000_000
    case .qwen3Small: return 450_000_000
    case .qwen3Large: return 1_800_000_000
    case .largeTurbo: return 1_500_000_000
    case .large: return 3_000_000_000
    case .distilLarge: return 800_000_000
    case .small, .smallEn: return 250_000_000
    case .base, .baseEn: return 80_000_000
    case .tiny, .tinyEn: return 40_000_000
    }
  }

  var memoryUsage: Int64 {
    switch self {
    case .graniteSpeech: return 2_000_000_000
    case .qwen3Small: return 1_300_000_000
    case .qwen3Large: return 3_500_000_000
    case .largeTurbo: return 3_000_000_000
    case .large: return 6_000_000_000
    case .distilLarge: return 2_000_000_000
    case .small, .smallEn: return 600_000_000
    case .base, .baseEn: return 200_000_000
    case .tiny, .tinyEn: return 100_000_000
    }
  }

  /// HuggingFace model identifier for Granite models
  var huggingFaceModelId: String? {
    switch self {
    case .graniteSpeech: return "ibm-granite/granite-4.0-1b-speech"
    case .qwen3Small: return "aufklarer/Qwen3-ASR-0.6B-MLX-4bit"
    case .qwen3Large: return "aufklarer/Qwen3-ASR-1.7B-MLX-8bit"
    default: return nil
    }
  }

  /// WhisperKit model repository identifier (how WhisperKit names folders)
  var whisperKitModelId: String? {
    switch self {
    case .graniteSpeech, .qwen3Small, .qwen3Large: return nil
    case .largeTurbo: return "openai_whisper-large-v3_turbo"
    case .large: return "openai_whisper-large-v3"
    case .distilLarge: return "distil-whisper_distil-large-v3"
    case .small: return "openai_whisper-small"
    case .base: return "openai_whisper-base"
    case .tiny: return "openai_whisper-tiny"
    case .smallEn: return "openai_whisper-small.en"
    case .baseEn: return "openai_whisper-base.en"
    case .tinyEn: return "openai_whisper-tiny.en"
    }
  }
}

/// Backward compatibility alias
typealias WhisperModel = SpeechModel

/// Manages downloading, storing, and selecting speech models
final class ModelManager: ObservableObject, @unchecked Sendable {
  static let shared = ModelManager()

  @Published var downloadProgress: [SpeechModel: Double] = [:]
  @Published var downloadedModels: Set<SpeechModel> = []
  @Published var isDownloading: [SpeechModel: Bool] = [:]
  @Published var downloadError: String?

  /// Model queued for automatic switch when idle (e.g. default model migration)
  @Published var pendingUpgradeModel: SpeechModel?

  private let fileManager = FileManager.default
  private var downloadTasks: [SpeechModel: Task<Void, Never>] = [:]
  private var graniteDownloadProcesses: [SpeechModel: Process] = [:]
  private var cancelledDownloads: Set<SpeechModel> = []

  private init() {
    loadDownloadedModels()
  }

  // MARK: - Model Hierarchy

  /// Use the smaller Qwen model on machines with less than 16 GB RAM.
  private static let largeQwenMemoryThresholdBytes: UInt64 = 16 * 1024 * 1024 * 1024

  /// The default/recommended model - native Qwen3 MLX, chosen by available RAM.
  static var defaultModel: SpeechModel {
    let physicalMemory = ProcessInfo.processInfo.physicalMemory
    return physicalMemory < largeQwenMemoryThresholdBytes ? .qwen3Small : .qwen3Large
  }

  // MARK: - CoreML Compilation Check

  /// Check if a model has likely been compiled by CoreML before (fast to load)
  /// CoreML caches compiled models, so subsequent loads are much faster
  /// Granite models are always considered "compiled" since they don't use CoreML
  func isLikelyCompiled(_ model: SpeechModel) -> Bool {
    if model.isGraniteModel || model.isQwenModel { return true }
    // Check for CoreML cache - this is where device-specific optimizations are stored
    // The cache location varies but we can check for common indicators

    guard let modelPath = modelPath(for: model) else { return false }
    let modelURL = URL(fileURLWithPath: modelPath)

    // Check if the AudioEncoder has a compiled data file (coremldata.bin)
    // This is created after first successful load
    let audioEncoderCompiled = modelURL
      .appendingPathComponent("AudioEncoder.mlmodelc/coremldata.bin")

    if fileManager.fileExists(atPath: audioEncoderCompiled.path) {
      // Check file size - compiled models have substantial coremldata.bin files
      if let attrs = try? fileManager.attributesOfItem(atPath: audioEncoderCompiled.path),
         let size = attrs[.size] as? Int64,
         size > 1_000_000 {  // > 1MB suggests it's been compiled
        return true
      }
    }

    return false
  }

  // MARK: - Paths

  var modelsDirectory: URL {
    let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    let voiceyDir = appSupport.appendingPathComponent("Voicey/Models", isDirectory: true)

    // Create directory if needed
    if !fileManager.fileExists(atPath: voiceyDir.path) {
      try? fileManager.createDirectory(at: voiceyDir, withIntermediateDirectories: true)
    }

    return voiceyDir
  }

  /// Returns the path to a model if it exists and is complete
  func modelPath(for model: SpeechModel) -> String? {
    if model.isGraniteModel {
      return graniteModelPath(for: model)
    }
    if model.isQwenModel {
      return qwenModelPath(for: model)
    }

    // WhisperKit stores models in: models/argmaxinc/whisperkit-coreml/{model_id}/
    guard let whisperKitId = model.whisperKitModelId else { return nil }
    let whisperKitPath =
      modelsDirectory
      .appendingPathComponent("models/argmaxinc/whisperkit-coreml")
      .appendingPathComponent(whisperKitId)

    if isModelComplete(at: whisperKitPath) {
      return whisperKitPath.path
    }

    return nil
  }

  /// Returns the path for a Qwen model if it has been downloaded
  private func qwenModelPath(for model: SpeechModel) -> String? {
    guard let qwenDir = qwenModelDirectory(for: model), isQwenModelComplete(at: qwenDir) else {
      return nil
    }
    return qwenDir.path
  }

  /// Returns the path for a Granite model if it has been downloaded
  private func graniteModelPath(for model: SpeechModel) -> String? {
    guard let hfId = model.huggingFaceModelId else { return nil }
    let granitePath = modelsDirectory.appendingPathComponent("granite").appendingPathComponent(hfId)
    // Check for a marker file that indicates successful download
    let markerPath = granitePath.appendingPathComponent(".download_complete")
    if fileManager.fileExists(atPath: markerPath.path) {
      return granitePath.path
    }
    return nil
  }

  /// Directory for Granite model storage
  func graniteModelDirectory(for model: SpeechModel) -> URL? {
    guard let hfId = model.huggingFaceModelId else { return nil }
    return modelsDirectory.appendingPathComponent("granite").appendingPathComponent(hfId)
  }

  /// Directory for Qwen model storage
  func qwenModelDirectory(for model: SpeechModel) -> URL? {
    guard let hfId = model.huggingFaceModelId, model.isQwenModel else { return nil }
    return try? HuggingFaceDownloader.getCacheDirectory(for: hfId)
  }

  private func isQwenModelComplete(at modelDir: URL) -> Bool {
    let requiredFiles = ["config.json", "merges.txt", "tokenizer_config.json", "vocab.json"]
    let hasRequiredFiles = requiredFiles.allSatisfy { file in
      fileManager.fileExists(atPath: modelDir.appendingPathComponent(file).path)
    }
    return hasRequiredFiles && HuggingFaceDownloader.weightsExist(in: modelDir)
  }

  /// Validates that a model directory has all required files for WhisperKit to load
  private func isModelComplete(at modelDir: URL) -> Bool {
    // Check if the model directory exists and has all essential files
    let configPath = modelDir.appendingPathComponent("config.json")
    guard fileManager.fileExists(atPath: configPath.path) else {
      return false
    }

    // Verify essential model components exist with their weight files
    // A complete model must have MelSpectrogram, AudioEncoder, and TextDecoder
    let essentialComponents = [
      "MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"
    ]

    for component in essentialComponents {
      let componentPath = modelDir.appendingPathComponent(component)

      // Check directory exists
      var isDir: ObjCBool = false
      guard fileManager.fileExists(atPath: componentPath.path, isDirectory: &isDir), isDir.boolValue
      else {
        AppLogger.model.warning("Model incomplete: missing \(component)")
        return false
      }

      // Check for compiled model (coremldata.bin) OR weights directory with weight.bin
      let coremlDataPath = componentPath.appendingPathComponent("coremldata.bin")
      let weightsPath = componentPath.appendingPathComponent("weights/weight.bin")

      let hasCoremlData = fileManager.fileExists(atPath: coremlDataPath.path)
      let hasWeights = fileManager.fileExists(atPath: weightsPath.path)

      // MelSpectrogram typically doesn't have weights (small model), but others do
      // At minimum, the directory should have model.mil or coremldata.bin
      let modelMilPath = componentPath.appendingPathComponent("model.mil")
      let hasModelMil = fileManager.fileExists(atPath: modelMilPath.path)

      if !hasCoremlData && !hasWeights && !hasModelMil {
        AppLogger.model.warning("Model incomplete: \(component) missing essential files")
        return false
      }
    }

    return true
  }

  var hasDownloadedModel: Bool {
    SpeechModel.userFacingModels.contains { isDownloaded($0) }
  }

  // MARK: - Model Discovery

  func loadDownloadedModels() {
    downloadedModels.removeAll()

    for model in SpeechModel.allCases where modelPath(for: model) != nil {
      downloadedModels.insert(model)
    }
  }

  func isDownloaded(_ model: WhisperModel) -> Bool {
    // Always check fresh in case files changed
    return modelPath(for: model) != nil
  }

  func modelFileSize(_ model: WhisperModel) -> Int64? {
    guard let path = modelPath(for: model) else { return nil }
    return directorySize(at: URL(fileURLWithPath: path))
  }

  private func directorySize(at url: URL) -> Int64 {
    var size: Int64 = 0
    let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
    while let fileURL = enumerator?.nextObject() as? URL {
      if let fileSize = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
        size += Int64(fileSize)
      }
    }
    return size
  }

  // MARK: - Download

  /// Downloads a model. Qwen models are used by the app; Whisper/Granite paths serve benchmark CLI tooling.
  func downloadModel(_ model: SpeechModel) {
    guard !isDownloading[model, default: false] else { return }
    cancelledDownloads.remove(model)

    if model.isGraniteModel {
      downloadGraniteModel(model)
      return
    }
    if model.isQwenModel {
      downloadQwenModel(model)
      return
    }

    isDownloading[model] = true
    downloadProgress[model] = 0
    downloadError = nil

    AppLogger.model.info("Starting download of model: \(model.displayName)")

    // Clean up any previous incomplete download before starting
    cleanupIncompleteDownload(model)

    let task = Task {
      do {
        let whisperProgressHandler: @Sendable (Progress) -> Void = { progress in
          Task { @MainActor in
            ModelManager.shared.downloadProgress[model] = progress.fractionCompleted
            AppLogger.model.debug("Download progress: \(Int(progress.fractionCompleted * 100))%")
          }
        }

        AppLogger.model.info("Starting WhisperKit download with progress tracking...")

        // Use the proper WhisperKit.download static function with progress callback
        let modelFolder = try await WhisperKit.download(
          variant: model.rawValue,
          downloadBase: modelsDirectory,
          useBackgroundSession: false,
          progressCallback: whisperProgressHandler
        )

        AppLogger.model.info("Download completed to: \(modelFolder.path)")

        // Verify the download actually succeeded by checking for config.json
        if modelPath(for: model) != nil {
          await MainActor.run {
            AppLogger.model.info("Model \(model.displayName) downloaded and verified successfully")
            loadDownloadedModels()
            downloadProgress[model] = 1.0
            isDownloading[model] = false
            downloadTasks[model] = nil
            NotificationManager.shared.showModelDownloadComplete(model: model)
          }
        } else {
          // Download seemed to complete but files are missing
          AppLogger.model.error(
            "Model download completed but verification failed - files may be incomplete")
          throw ModelDownloadError.verificationFailed
        }
      } catch {
        await MainActor.run {
          if !Task.isCancelled {
            let errorMessage = Self.classifyDownloadError(error)
            AppLogger.model.error("Model download failed: \(errorMessage) (underlying: \(error))")
            downloadError = errorMessage
            NotificationManager.shared.showModelDownloadFailed(reason: errorMessage)
          }
          isDownloading[model] = false
          downloadProgress[model] = 0
          downloadTasks[model] = nil
        }
      }
    }

    downloadTasks[model] = task
  }

  /// Download a Qwen model directly from Hugging Face without Python runtime dependencies.
  private func downloadQwenModel(_ model: SpeechModel) {
    guard let hfId = model.huggingFaceModelId else { return }

    isDownloading[model] = true
    downloadProgress[model] = 0
    downloadError = nil

    cleanupIncompleteDownload(model)

    let task = Task {
      do {
        try await VoiceyQwenDownloadSerialExecutor.shared.perform {
          if VoiceyRuntimeConfiguration.useRustFetch {
            try await VoiceyFetchWorkerSession.shared.ping()
          }

          guard let modelDir = qwenModelDirectory(for: model) else {
            throw ModelDownloadError.verificationFailed
          }

          try fileManager.createDirectory(at: modelDir, withIntermediateDirectories: true)
          let qwenProgressHandler: @Sendable (Double) -> Void = { progress in
            Task { @MainActor in
              ModelManager.shared.downloadProgress[model] = progress
            }
          }
          if VoiceyRuntimeConfiguration.useRustFetch {
            try await VoiceyRustQwenDownloader.downloadWeights(
              modelId: hfId,
              to: modelDir,
              additionalFiles: ["vocab.json", "merges.txt", "tokenizer_config.json"],
              progressHandler: qwenProgressHandler
            )
          } else {
            try await HuggingFaceDownloader.downloadWeights(
              modelId: hfId,
              to: modelDir,
              additionalFiles: ["vocab.json", "merges.txt", "tokenizer_config.json"],
              progressHandler: qwenProgressHandler
            )
          }
        }

        guard modelPath(for: model) != nil else {
          throw ModelDownloadError.verificationFailed
        }

        await MainActor.run {
          loadDownloadedModels()
          downloadProgress[model] = 1.0
          isDownloading[model] = false
          downloadTasks[model] = nil
          NotificationManager.shared.showModelDownloadComplete(model: model)
        }
      } catch is CancellationError {
        await MainActor.run {
          cleanupIncompleteDownload(model)
          loadDownloadedModels()
          isDownloading[model] = false
          downloadProgress[model] = 0
          downloadTasks[model] = nil
        }
      } catch {
        await MainActor.run {
          cleanupIncompleteDownload(model)
          loadDownloadedModels()
          let errorMessage = Self.classifyDownloadError(error)
          AppLogger.model.error("Qwen model download failed: \(errorMessage) (underlying: \(error))")
          downloadError = errorMessage
          isDownloading[model] = false
          downloadProgress[model] = 0
          downloadTasks[model] = nil
          NotificationManager.shared.showModelDownloadFailed(reason: errorMessage)
        }
      }
    }

    downloadTasks[model] = task
  }

  /// Download a Granite model using huggingface-cli or Python
  private func downloadGraniteModel(_ model: SpeechModel) {
    guard let hfId = model.huggingFaceModelId else { return }

    isDownloading[model] = true
    downloadProgress[model] = 0
    downloadError = nil

    AppLogger.model.info("Starting Granite model download: \(model.displayName)")

    let task = Task { @MainActor in
      do {
        guard let modelDir = graniteModelDirectory(for: model) else {
          throw ModelDownloadError.verificationFailed
        }

        // Create directory
        try? fileManager.createDirectory(at: modelDir, withIntermediateDirectories: true)

        // Use Python to download the model via huggingface_hub
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
                  repo_id="\(hfId)",
                  local_dir="\(modelDir.path)",
                  local_dir_use_symlinks=False
              )
              # Write marker file
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

        let outputBuffer = GraniteDownloadOutputBuffer()
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
          let data = handle.availableData
          guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
          Task {
            await outputBuffer.appendStdout(chunk)
          }

          if let progress = Self.extractDownloadProgress(from: chunk) {
            Task { @MainActor [weak self] in
              guard self?.isDownloading[model] == true else { return }
              self?.downloadProgress[model] = progress
            }
          }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
          let data = handle.availableData
          guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
          Task {
            await outputBuffer.appendStderr(chunk)
          }

          if let progress = Self.extractDownloadProgress(from: chunk) {
            Task { @MainActor [weak self] in
              guard self?.isDownloading[model] == true else { return }
              self?.downloadProgress[model] = progress
            }
          }
        }

        try process.run()
        graniteDownloadProcesses[model] = process

        // Monitor in background
        let modelRef = model
        let managerRef = self

        Task.detached {
          process.waitUntilExit()

          outputPipe.fileHandleForReading.readabilityHandler = nil
          errorPipe.fileHandleForReading.readabilityHandler = nil

          if let finalStdout = String(
            data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) {
            await outputBuffer.appendStdout(finalStdout)
          }
          if let finalStderr = String(
            data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) {
            await outputBuffer.appendStderr(finalStderr)
          }

          let exitCode = process.terminationStatus
          let (outputLog, errorOutput) = await outputBuffer.snapshot()

          await MainActor.run {
            managerRef.graniteDownloadProcesses[modelRef] = nil

            if managerRef.cancelledDownloads.contains(modelRef) {
              managerRef.cancelledDownloads.remove(modelRef)
              managerRef.isDownloading[modelRef] = false
              managerRef.downloadProgress[modelRef] = 0
              managerRef.downloadTasks[modelRef] = nil
              return
            }

            if exitCode == 0 && managerRef.modelPath(for: modelRef) != nil {
              AppLogger.model.info("Granite model \(modelRef.displayName) downloaded successfully")
              managerRef.loadDownloadedModels()
              managerRef.downloadProgress[modelRef] = 1.0
              managerRef.isDownloading[modelRef] = false
              managerRef.downloadTasks[modelRef] = nil
              NotificationManager.shared.showModelDownloadComplete(model: modelRef)
            } else {
              let errorMessage = errorOutput.isEmpty
                ? "Failed to download Granite model. Ensure Python 3 and huggingface_hub are installed (pip3 install huggingface_hub)."
                : errorOutput
              AppLogger.model.error("Granite model download failed: \(errorMessage)")
              if !outputLog.isEmpty {
                AppLogger.model.error("Granite model download output: \(outputLog)")
              }
              managerRef.downloadError = errorMessage
              managerRef.isDownloading[modelRef] = false
              managerRef.downloadProgress[modelRef] = 0
              managerRef.downloadTasks[modelRef] = nil
              NotificationManager.shared.showModelDownloadFailed(reason: errorMessage)
            }
          }
        }
      } catch {
        if !Task.isCancelled {
          let errorMessage = "Failed to start download: \(error.localizedDescription)"
          AppLogger.model.error("Granite model download failed: \(errorMessage)")
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

  private static func extractDownloadProgress(from text: String) -> Double? {
    // Parse percentages from huggingface_hub/tqdm output (e.g. " 42%|")
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

    let bounded = min(max(percentValue, 0), 100)
    return Double(bounded) / 100.0
  }

  /// Classify download errors into user-friendly messages
  private static func classifyDownloadError(_ error: Error) -> String {
    let errorString = error.localizedDescription.lowercased()
    let nsError = error as NSError

    // Check for network-related errors
    if nsError.domain == NSURLErrorDomain {
      switch nsError.code {
      case NSURLErrorNotConnectedToInternet:
        return "No internet connection. Please check your network and try again."
      case NSURLErrorTimedOut:
        return "Download timed out. Please check your network connection and try again."
      case NSURLErrorNetworkConnectionLost:
        return "Network connection was lost. Please try again."
      case NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost:
        return "Cannot reach the model server. Please check your internet connection."
      case NSURLErrorSecureConnectionFailed:
        return "Secure connection failed. Please try again later."
      default:
        return "Network error: \(error.localizedDescription)"
      }
    }

    // Check for common error patterns in the message
    if errorString.contains("network") || errorString.contains("internet")
      || errorString.contains("connection") {
      return "Network error: Please check your internet connection and try again."
    }

    if errorString.contains("disk") || errorString.contains("space")
      || errorString.contains("storage") {
      return "Insufficient disk space. Please free up some storage and try again."
    }

    if errorString.contains("permission") || errorString.contains("access") {
      return "Permission denied. Please check app permissions."
    }

    // Check if it's our verification error
    if error is ModelDownloadError {
      return "Download incomplete. Please try again."
    }

    return "Download failed: \(error.localizedDescription)"
  }

  /// Custom errors for model management
  enum ModelDownloadError: LocalizedError {
    case verificationFailed
    case networkUnavailable

    var errorDescription: String? {
      switch self {
      case .verificationFailed:
        return "Model download verification failed"
      case .networkUnavailable:
        return "Network is unavailable"
      }
    }
  }

  func cancelDownload(_ model: WhisperModel) {
    if let process = graniteDownloadProcesses[model], process.isRunning {
      cancelledDownloads.insert(model)
      process.terminate()
      if process.isRunning {
        process.interrupt()
      }
      graniteDownloadProcesses[model] = nil
    }

    downloadTasks[model]?.cancel()
    downloadTasks[model] = nil
    isDownloading[model] = false
    downloadProgress[model] = 0
  }

  /// Removes any incomplete/corrupted model files to allow a fresh download
  func cleanupIncompleteDownload(_ model: SpeechModel) {
    if model.isGraniteModel {
      // For Granite models, just remove the directory if marker is missing
      if let dir = graniteModelDirectory(for: model),
         fileManager.fileExists(atPath: dir.path),
         !fileManager.fileExists(atPath: dir.appendingPathComponent(".download_complete").path) {
        try? fileManager.removeItem(at: dir)
      }
      return
    }
    if model.isQwenModel {
      if let dir = qwenModelDirectory(for: model),
         fileManager.fileExists(atPath: dir.path),
         !isQwenModelComplete(at: dir) {
        try? fileManager.removeItem(at: dir)
      }
      return
    }

    guard let whisperKitId = model.whisperKitModelId else { return }
    let whisperKitPath =
      modelsDirectory
      .appendingPathComponent("models/argmaxinc/whisperkit-coreml")
      .appendingPathComponent(whisperKitId)

    let cachePath =
      modelsDirectory
      .appendingPathComponent("models/argmaxinc/whisperkit-coreml/.cache/huggingface/download")
      .appendingPathComponent(whisperKitId)

    // Only cleanup if the model exists but is incomplete
    if fileManager.fileExists(atPath: whisperKitPath.path) && !isModelComplete(at: whisperKitPath) {
      AppLogger.model.info("Cleaning up incomplete model at \(whisperKitPath.path)")
      do {
        try fileManager.removeItem(at: whisperKitPath)
      } catch {
        AppLogger.model.error("Failed to clean up incomplete model: \(error)")
      }
    }

    // Also cleanup the download cache for this model
    if fileManager.fileExists(atPath: cachePath.path) {
      AppLogger.model.info("Cleaning up download cache at \(cachePath.path)")
      do {
        try fileManager.removeItem(at: cachePath)
      } catch {
        AppLogger.model.error("Failed to clean up download cache: \(error)")
      }
    }
  }

  // MARK: - Delete

  func deleteModel(_ model: SpeechModel) throws {
    if model.isGraniteModel {
      if let dir = graniteModelDirectory(for: model),
         fileManager.fileExists(atPath: dir.path) {
        try fileManager.removeItem(at: dir)
      }
      downloadedModels.remove(model)
      downloadProgress[model] = 0
      return
    }
    if model.isQwenModel {
      if let dir = qwenModelDirectory(for: model),
         fileManager.fileExists(atPath: dir.path) {
        try fileManager.removeItem(at: dir)
      }
      downloadedModels.remove(model)
      downloadProgress[model] = 0
      return
    }

    // Delete from WhisperKit's nested path
    guard let whisperKitId = model.whisperKitModelId else { return }
    let whisperKitPath =
      modelsDirectory
      .appendingPathComponent("models/argmaxinc/whisperkit-coreml")
      .appendingPathComponent(whisperKitId)

    if fileManager.fileExists(atPath: whisperKitPath.path) {
      try fileManager.removeItem(at: whisperKitPath)
    }

    // Also try direct path
    let directPath = modelsDirectory.appendingPathComponent(whisperKitId)
    if fileManager.fileExists(atPath: directPath.path) {
      try fileManager.removeItem(at: directPath)
    }

    downloadedModels.remove(model)
    downloadProgress[model] = 0
  }

  // MARK: - Formatting

  static func formatSize(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
  }
}

private actor GraniteDownloadOutputBuffer {
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
