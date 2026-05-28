import AudioCommon
import Foundation

/// Downloads Qwen MLX weights via `voicey-fetch` (hot path when the worker binary is bundled).
enum VoiceyRustQwenDownloader {
  private static let defaultRevision = "main"
  private static let requiredConfigFile = "config.json"
  private static let defaultWeightGlob = "*.safetensors"
  private static let weightIndexFile = "model.safetensors.index.json"
  private static let stagingDirectoryName = ".voicey-fetch-staging"
  private static let stagingContainerPrefix = ".voicey-fetch-download-"

  static func downloadWeights(
    modelId: String,
    to directory: URL,
    additionalFiles: [String],
    progressHandler: ((Double) -> Void)? = nil
  ) async throws {
    let files = try await listWeightFiles(modelId: modelId, additionalFiles: additionalFiles)
    guard !files.isEmpty else {
      throw DownloadError.failedToDownload("\(modelId): no files matched")
    }

    let fileManager = FileManager.default
    let stagingContainer = try makeStagingContainer(for: directory, fileManager: fileManager)
    let stagedModelRoot = stagingContainer.appendingPathComponent(
      stagingDirectoryName, isDirectory: true)
    defer { try? fileManager.removeItem(at: stagingContainer) }

    for (index, relativePath) in files.enumerated() {
      let validated = try HuggingFaceDownloader.validatedRemoteFileName(relativePath)
      let stagedDestination = try HuggingFaceDownloader.validatedLocalPath(
        directory: stagedModelRoot, fileName: validated)

      let stagedPath = try await VoiceyFetchWorkerSession.shared.downloadModelFile(
        modelID: modelId,
        revision: defaultRevision,
        relativePath: validated,
        modelRoot: stagingContainer.path
      )
      let stagedURL = URL(fileURLWithPath: stagedPath)
      if stagedURL.standardizedFileURL != stagedDestination.standardizedFileURL {
        throw DownloadError.failedToDownload("\(modelId): staged path mismatch for \(validated)")
      }

      progressHandler?(Double(index + 1) / Double(files.count))
    }

    guard fileManager.fileExists(atPath: stagedModelRoot.path) else {
      throw DownloadError.failedToDownload("\(modelId): staged model root missing")
    }
    try promoteStagedModel(from: stagedModelRoot, to: directory, fileManager: fileManager)
  }

  private static func listWeightFiles(modelId: String, additionalFiles: [String]) async throws -> [String] {
    var globs = [requiredConfigFile]
    let hasExplicitWeights = additionalFiles.contains { $0.hasSuffix(".safetensors") }
    if !hasExplicitWeights {
      globs.append(defaultWeightGlob)
      globs.append(weightIndexFile)
    }
    for file in additionalFiles where !globs.contains(file) {
      globs.append(file)
    }

    return try await VoiceyFetchWorkerSession.shared.listModelFiles(
      modelID: modelId,
      revision: defaultRevision,
      patterns: globs
    )
  }

  private static func makeStagingContainer(for directory: URL, fileManager: FileManager) throws -> URL {
    let parentDirectory = directory.deletingLastPathComponent()
    try fileManager.createDirectory(at: parentDirectory, withIntermediateDirectories: true)

    let stagingContainer = parentDirectory.appendingPathComponent(
      "\(stagingContainerPrefix)\(directory.lastPathComponent)-\(UUID().uuidString)",
      isDirectory: true
    )
    try fileManager.createDirectory(at: stagingContainer, withIntermediateDirectories: true)
    return stagingContainer
  }

  private static func promoteStagedModel(
    from stagedModelRoot: URL,
    to destination: URL,
    fileManager: FileManager
  ) throws {
    if fileManager.fileExists(atPath: destination.path) {
      try fileManager.removeItem(at: destination)
    }
    try fileManager.moveItem(at: stagedModelRoot, to: destination)
  }
}
