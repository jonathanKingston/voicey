import AudioCommon
import Foundation

/// Downloads Qwen MLX weights via `voicey-fetch` (hot path when the worker binary is bundled).
enum VoiceyRustQwenDownloader {
  private static let huggingFaceHost = "https://huggingface.co"

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
    let stagingRoot = directory.appendingPathComponent(".voicey-fetch-staging", isDirectory: true)
    try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: stagingRoot) }

    for (index, relativePath) in files.enumerated() {
      let validated = try HuggingFaceDownloader.validatedRemoteFileName(relativePath)
      let destination = try HuggingFaceDownloader.validatedLocalPath(directory: directory, fileName: validated)
      let stagingPath = stagingRoot.appendingPathComponent(validated)
      try fileManager.createDirectory(
        at: stagingPath.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )

      let url = "\(huggingFaceHost)/\(modelId)/resolve/main/\(validated)"
      try await VoiceyFetchWorkerSession.shared.downloadHFFile(
        url: url,
        stagingPath: stagingPath.path
      )

      if fileManager.fileExists(atPath: destination.path) {
        try fileManager.removeItem(at: destination)
      }
      try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
      try fileManager.moveItem(at: stagingPath, to: destination)

      progressHandler?(Double(index + 1) / Double(files.count))
    }
  }

  private struct TreeEntry: Decodable {
    let path: String
    let type: String
  }

  private static func listWeightFiles(modelId: String, additionalFiles: [String]) async throws -> [String] {
    var globs = ["config.json"]
    let hasExplicitWeights = additionalFiles.contains { $0.hasSuffix(".safetensors") }
    if !hasExplicitWeights {
      globs.append("*.safetensors")
      globs.append("model.safetensors.index.json")
    }
    for file in additionalFiles where !globs.contains(file) {
      globs.append(file)
    }

    let encodedModel = modelId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? modelId
    guard let url = URL(string: "\(huggingFaceHost)/api/models/\(encodedModel)/tree/main?recursive=1") else {
      throw DownloadError.failedToDownload(modelId)
    }

    var request = URLRequest(url: url)
    request.setValue("voicey-fetch/1.0", forHTTPHeaderField: "User-Agent")
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
      throw DownloadError.failedToDownload("\(modelId): HF tree HTTP error")
    }

    let entries = try JSONDecoder().decode([TreeEntry].self, from: data)
    let filePaths = entries.filter { $0.type == "file" }.map(\.path)
    return filePaths.filter { path in
      globs.contains { globMatches(glob: $0, path: path) }
    }.sorted()
  }

  private static func globMatches(glob: String, path: String) -> Bool {
    if glob == path { return true }
    if glob.hasPrefix("*."), path.hasSuffix(String(glob.dropFirst())) { return true }
    if glob == "*.safetensors", path.hasSuffix(".safetensors") { return true }
    return false
  }
}
