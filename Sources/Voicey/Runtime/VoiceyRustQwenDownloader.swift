import AudioCommon
import Foundation

/// Downloads Qwen MLX weights via `voicey-fetch` (hot path when the worker binary is bundled).
enum VoiceyRustQwenDownloader {
  private static let defaultRevision = "main"
  private static let requiredConfigFile = "config.json"
  private static let defaultWeightGlob = "*.safetensors"
  private static let weightIndexFile = "model.safetensors.index.json"
  private static let stagingDirectoryName = ".voicey-fetch-staging"

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
    let stagingRoot = directory.appendingPathComponent(stagingDirectoryName, isDirectory: true)
    try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: stagingRoot) }

    for (index, relativePath) in files.enumerated() {
      let validated = try HuggingFaceDownloader.validatedRemoteFileName(relativePath)
      let destination = try HuggingFaceDownloader.validatedLocalPath(
        directory: directory, fileName: validated)

      let stagedPath = try await VoiceyFetchWorkerSession.shared.downloadModelFile(
        modelID: modelId,
        revision: defaultRevision,
        relativePath: validated,
        modelRoot: directory.path
      )
      let stagedURL = URL(fileURLWithPath: stagedPath)

      if fileManager.fileExists(atPath: destination.path) {
        try fileManager.removeItem(at: destination)
      }
      try fileManager.createDirectory(
        at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
      try fileManager.moveItem(at: stagedURL, to: destination)

      progressHandler?(Double(index + 1) / Double(files.count))
    }
  }

  private static func listWeightFiles(modelId: String, additionalFiles: [String]) async throws
    -> [String]
  {
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
}
