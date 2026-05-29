import AudioCommon
import Combine
import Foundation
import WhisperKit
import os

// ModelManager owns download, update, and revision-tracking responsibilities.
// Keep size warnings disabled until these concerns are split into focused types.
// swiftlint:disable type_body_length file_length

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

  /// Models shown in settings and download UI
  static var userFacingModels: [SpeechModel] {
    [.qwen3Large, .qwen3Small]
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
    case .graniteSpeech:
      return "#1 on OpenASR leaderboard, multilingual, ~1GB (requires Python + mlx-audio)"
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

/// Callback for when a background model upgrade completes
typealias ModelUpgradeCallback = (SpeechModel) -> Void

enum ModelUpdateStatus: Equatable {
  case checking
  case upToDate
  case updateAvailable
  case failed(String)
}

struct ModelRevisionMetadata: Codable, Equatable {
  let sourceIdentifier: String
  let fingerprint: String
  let recordedAt: Date
}

private struct RemoteModelRevision {
  let source: ModelRevisionSource
  let fingerprint: String
  let files: [HuggingFaceTreeItem]

  var sourceIdentifier: String {
    source.sourceIdentifier
  }
}

private struct ModelRevisionSource {
  let repositoryID: String
  let pathPrefix: String?

  var sourceIdentifier: String {
    if let pathPrefix {
      return "\(repositoryID):\(pathPrefix)"
    }
    return repositoryID
  }
}

private struct HuggingFaceTreeItem: Decodable {
  struct LFSInfo: Decodable {
    let oid: String?
  }

  let type: String
  let oid: String
  let size: Int64?
  let path: String
  let lfs: LFSInfo?

  var isFile: Bool {
    type == "file"
  }

  var remoteFingerprintPart: String {
    "\(path):\(oid):\(lfs?.oid ?? ""):\(size ?? 0)"
  }
}
/// Manages downloading, storing, and selecting speech models
final class ModelManager: ObservableObject, @unchecked Sendable {
  static let shared = ModelManager()

  @Published var downloadProgress: [SpeechModel: Double] = [:]
  @Published var downloadedModels: Set<SpeechModel> = []
  @Published var isDownloading: [SpeechModel: Bool] = [:]
  @Published var isUpdating: [SpeechModel: Bool] = [:]
  @Published var downloadError: String?
  @Published private(set) var modelRevisionMetadata: [SpeechModel: ModelRevisionMetadata] = [:]
  @Published private(set) var modelUpdateStatus: [SpeechModel: ModelUpdateStatus] = [:]

  /// Model queued for automatic switch when idle (e.g. default model migration)
  @Published var pendingUpgradeModel: SpeechModel?

  private let fileManager = FileManager.default
  private let metadataDefaults = SettingsManager.defaultsStore
  private var downloadTasks: [SpeechModel: Task<Void, Never>] = [:]
  private var graniteDownloadProcesses: [SpeechModel: Process] = [:]
  private var cancelledDownloads: Set<SpeechModel> = []

  private static let huggingFaceAPIBaseURL = "https://huggingface.co/api/models"
  private static let huggingFaceRevision = "main"
  private static let whisperKitRepositoryID = "argmaxinc/whisperkit-coreml"
  private static let revisionMetadataDefaultsKey = "modelRevisionMetadata.v1"

  private init() {
    loadRevisionMetadata()
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
    let audioEncoderCompiled =
      modelURL
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

  func hasKnownRevision(for model: SpeechModel) -> Bool {
    modelRevisionMetadata[model] != nil
  }

  func checkForUpdatesForDownloadedModels() {
    for model in downloadedModels {
      checkForModelUpdate(model)
    }
  }

  func checkForModelUpdate(_ model: SpeechModel) {
    guard isDownloaded(model), isUpdating[model, default: false] == false else { return }

    modelUpdateStatus[model] = .checking

    Task {
      do {
        let remoteRevision = try await fetchRemoteRevision(for: model)
        await MainActor.run {
          guard self.isDownloaded(model) else {
            self.modelUpdateStatus[model] = nil
            return
          }

          if let storedMetadata = self.modelRevisionMetadata[model] {
            self.modelUpdateStatus[model] =
              self.statusForKnownRevision(storedMetadata, remoteRevision: remoteRevision)
          } else if self.localFilesMatchRemoteRevision(remoteRevision, for: model) {
            self.recordRevision(remoteRevision, for: model)
            self.modelUpdateStatus[model] = .upToDate
          } else {
            self.modelUpdateStatus[model] = .updateAvailable
          }
        }
      } catch {
        await MainActor.run {
          self.modelUpdateStatus[model] = .failed(Self.classifyDownloadError(error))
        }
      }
    }
  }

  func updateDownloadedModel(_ model: SpeechModel) {
    guard !isUpdating[model, default: false],
      !isDownloading[model, default: false],
      let existingPath = modelPath(for: model)
    else {
      return
    }

    isUpdating[model] = true
    modelUpdateStatus[model] = .checking
    downloadError = nil
    let hasStoredRevision = modelRevisionMetadata[model] != nil

    let existingURL = URL(fileURLWithPath: existingPath)
    let backupURL =
      existingURL
      .deletingLastPathComponent()
      .appendingPathComponent(
        "\(existingURL.lastPathComponent).voicey-update-backup-\(UUID().uuidString)")

    Task {
      do {
        if !hasStoredRevision {
          let remoteRevision = try await fetchRemoteRevision(for: model)
          if localFilesMatchRemoteRevision(remoteRevision, for: model) {
            await MainActor.run {
              self.recordRevision(remoteRevision, for: model)
              self.modelUpdateStatus[model] = .upToDate
              self.isUpdating[model] = false
            }
            return
          }
        }

        try fileManager.moveItem(at: existingURL, to: backupURL)

        await MainActor.run {
          self.downloadModel(model)
        }

        while await isModelDownloading(model) {
          try await Task.sleep(nanoseconds: 500_000_000)
        }

        guard modelPath(for: model) != nil else {
          restoreBackup(for: model, from: backupURL, to: existingURL)
          throw ModelDownloadError.verificationFailed
        }

        try? fileManager.removeItem(at: backupURL)
        let recordedRevision = await recordDownloadedRevisionIfAvailable(for: model)

        await MainActor.run {
          self.loadDownloadedModels()
          self.isUpdating[model] = false
          if recordedRevision {
            self.modelUpdateStatus[model] = .upToDate
          }
        }
      } catch {
        restoreBackup(for: model, from: backupURL, to: existingURL)

        await MainActor.run {
          self.loadDownloadedModels()
          self.isUpdating[model] = false
          let errorMessage = Self.classifyDownloadError(error)
          self.downloadError = errorMessage
          self.modelUpdateStatus[model] = .failed(errorMessage)
        }
      }
    }
  }

  private func isModelDownloading(_ model: SpeechModel) async -> Bool {
    await MainActor.run {
      self.isDownloading[model, default: false]
    }
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
          await recordDownloadedRevisionIfAvailable(for: model)
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
        await recordDownloadedRevisionIfAvailable(for: model)
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
          AppLogger.model.error(
            "Qwen model download failed: \(errorMessage) (underlying: \(error))")
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
              Task {
                await managerRef.recordDownloadedRevisionIfAvailable(for: modelRef)
              }
              managerRef.loadDownloadedModels()
              managerRef.downloadProgress[modelRef] = 1.0
              managerRef.isDownloading[modelRef] = false
              managerRef.downloadTasks[modelRef] = nil
              NotificationManager.shared.showModelDownloadComplete(model: modelRef)
            } else {
              let errorMessage =
                errorOutput.isEmpty
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

    // Check if it's one of our model-management errors
    if let modelError = error as? ModelDownloadError {
      switch modelError {
      case .verificationFailed:
        return "Download incomplete. Please try again."
      case .networkUnavailable:
        return "Network is unavailable. Please check your connection and try again."
      case .serverError(let statusCode):
        return "Model server returned HTTP \(statusCode). Please try again later."
      }
    }

    return "Download failed: \(error.localizedDescription)"
  }

  /// Custom errors for model management
  enum ModelDownloadError: LocalizedError {
    case verificationFailed
    case networkUnavailable
    case serverError(Int)

    var errorDescription: String? {
      switch self {
      case .verificationFailed:
        return "Model download verification failed"
      case .networkUnavailable:
        return "Network is unavailable"
      case .serverError(let statusCode):
        return "Model server returned HTTP \(statusCode)"
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
      removeRevisionMetadata(for: model)
      return
    }
    if model.isQwenModel {
      if let dir = qwenModelDirectory(for: model),
        fileManager.fileExists(atPath: dir.path) {
        try fileManager.removeItem(at: dir)
      }
      downloadedModels.remove(model)
      downloadProgress[model] = 0
      removeRevisionMetadata(for: model)
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
    removeRevisionMetadata(for: model)
  }

  private func loadRevisionMetadata() {
    guard let data = metadataDefaults.data(forKey: Self.revisionMetadataDefaultsKey) else {
      modelRevisionMetadata = [:]
      return
    }

    do {
      let storedMetadata = try JSONDecoder().decode(
        [String: ModelRevisionMetadata].self, from: data)
      modelRevisionMetadata = storedMetadata.reduce(into: [:]) { result, element in
        guard let model = SpeechModel(rawValue: element.key) else { return }
        result[model] = element.value
      }
    } catch {
      AppLogger.model.error("Failed to decode model revision metadata: \(error)")
      modelRevisionMetadata = [:]
    }
  }

  private func saveRevisionMetadata() {
    let storedMetadata = modelRevisionMetadata.reduce(into: [String: ModelRevisionMetadata]()) { result, element in
      result[element.key.rawValue] = element.value
    }

    do {
      let data = try JSONEncoder().encode(storedMetadata)
      metadataDefaults.set(data, forKey: Self.revisionMetadataDefaultsKey)
    } catch {
      AppLogger.model.error("Failed to encode model revision metadata: \(error)")
    }
  }

  private func removeRevisionMetadata(for model: SpeechModel) {
    modelRevisionMetadata[model] = nil
    modelUpdateStatus[model] = nil
    saveRevisionMetadata()
  }

  @discardableResult
  private func recordDownloadedRevisionIfAvailable(for model: SpeechModel) async -> Bool {
    do {
      let remoteRevision = try await fetchRemoteRevision(for: model)
      await MainActor.run {
        self.modelRevisionMetadata[model] = ModelRevisionMetadata(
          sourceIdentifier: remoteRevision.sourceIdentifier,
          fingerprint: remoteRevision.fingerprint,
          recordedAt: Date()
        )
        self.modelUpdateStatus[model] = .upToDate
        self.saveRevisionMetadata()
      }
      return true
    } catch {
      await MainActor.run {
        AppLogger.model.error(
          "Failed to record remote revision for \(model.displayName): \(error)"
        )
        self.modelUpdateStatus[model] = .failed(Self.classifyDownloadError(error))
      }
      return false
    }
  }

  private func fetchRemoteRevision(for model: SpeechModel) async throws -> RemoteModelRevision {
    let source = try revisionSource(for: model)
    let url = try huggingFaceTreeURL(for: source)
    var request = URLRequest(url: url)
    request.timeoutInterval = 20

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw ModelDownloadError.verificationFailed
    }
    guard (200..<300).contains(httpResponse.statusCode) else {
      throw ModelDownloadError.serverError(httpResponse.statusCode)
    }

    let treeItems = try JSONDecoder().decode([HuggingFaceTreeItem].self, from: data)
    let fileFingerprints =
      treeItems
      .filter(\.isFile)
      .map(\.remoteFingerprintPart)
      .sorted()

    guard !fileFingerprints.isEmpty else {
      throw ModelDownloadError.verificationFailed
    }

    return RemoteModelRevision(
      source: source,
      fingerprint: Self.stableFingerprint(for: fileFingerprints),
      files: treeItems.filter(\.isFile)
    )
  }

  private func statusForKnownRevision(
    _ storedMetadata: ModelRevisionMetadata,
    remoteRevision: RemoteModelRevision
  ) -> ModelUpdateStatus {
    remoteRevision.sourceIdentifier == storedMetadata.sourceIdentifier
      && remoteRevision.fingerprint == storedMetadata.fingerprint
      ? .upToDate
      : .updateAvailable
  }

  private func recordRevision(_ remoteRevision: RemoteModelRevision, for model: SpeechModel) {
    modelRevisionMetadata[model] = ModelRevisionMetadata(
      sourceIdentifier: remoteRevision.sourceIdentifier,
      fingerprint: remoteRevision.fingerprint,
      recordedAt: Date()
    )
    saveRevisionMetadata()
  }

  private func localFilesMatchRemoteRevision(
    _ remoteRevision: RemoteModelRevision,
    for model: SpeechModel
  ) -> Bool {
    guard let modelPath = modelPath(for: model) else { return false }

    let modelURL = URL(fileURLWithPath: modelPath)
    guard !remoteRevision.files.isEmpty else { return false }

    for item in remoteRevision.files {
      guard
        let relativePath = localRelativePath(
          forRemotePath: item.path,
          source: remoteRevision.source
        )
      else {
        return false
      }

      let localURL = modelURL.appendingPathComponent(relativePath)
      guard let expectedSize = item.size,
        localFileSize(at: localURL) == expectedSize
      else {
        return false
      }
    }

    return true
  }

  private func localRelativePath(
    forRemotePath remotePath: String,
    source: ModelRevisionSource
  ) -> String? {
    guard let pathPrefix = source.pathPrefix else {
      return remotePath
    }

    let prefixWithSeparator = "\(pathPrefix)/"
    if remotePath.hasPrefix(prefixWithSeparator) {
      return String(remotePath.dropFirst(prefixWithSeparator.count))
    }

    return remotePath == pathPrefix ? "" : nil
  }

  private func localFileSize(at url: URL) -> Int64? {
    guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
      let size = attrs[.size] as? Int64
    else {
      return nil
    }
    return size
  }

  private func revisionSource(for model: SpeechModel) throws -> ModelRevisionSource {
    if let whisperKitModelId = model.whisperKitModelId {
      return ModelRevisionSource(
        repositoryID: Self.whisperKitRepositoryID,
        pathPrefix: whisperKitModelId
      )
    }

    guard let huggingFaceModelId = model.huggingFaceModelId else {
      throw ModelDownloadError.verificationFailed
    }

    return ModelRevisionSource(repositoryID: huggingFaceModelId, pathPrefix: nil)
  }

  private func huggingFaceTreeURL(for source: ModelRevisionSource) throws -> URL {
    var urlString =
      "\(Self.huggingFaceAPIBaseURL)/\(source.repositoryID)/tree/\(Self.huggingFaceRevision)"
    if let pathPrefix = source.pathPrefix {
      let allowedCharacters = CharacterSet.urlPathAllowed.subtracting(
        CharacterSet(charactersIn: "?#"))
      guard
        let encodedPath = pathPrefix.addingPercentEncoding(withAllowedCharacters: allowedCharacters)
      else {
        throw ModelDownloadError.verificationFailed
      }
      urlString += "/\(encodedPath)"
    }
    urlString += "?recursive=true"

    guard let url = URL(string: urlString) else {
      throw ModelDownloadError.verificationFailed
    }
    return url
  }

  private func restoreBackup(for model: SpeechModel, from backupURL: URL, to originalURL: URL) {
    guard fileManager.fileExists(atPath: backupURL.path) else { return }

    if fileManager.fileExists(atPath: originalURL.path) {
      try? fileManager.removeItem(at: originalURL)
    }

    do {
      try fileManager.moveItem(at: backupURL, to: originalURL)
    } catch {
      AppLogger.model.error("Failed to restore \(model.displayName) after update failure: \(error)")
    }
  }

  private static func stableFingerprint(for parts: [String]) -> String {
    var hash: UInt64 = 14_695_981_039_346_656_037
    let prime: UInt64 = 1_099_511_628_211

    for byte in parts.joined(separator: "\n").utf8 {
      hash ^= UInt64(byte)
      hash = hash &* prime
    }

    return String(format: "%016llx", hash)
  }
  // MARK: - Formatting

  static func formatSize(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
  }
}
// swiftlint:enable type_body_length

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
