import Foundation

enum BenchmarkModelDownloadCommand {
  private static let commandName = "benchmark-download-models"

  static func canHandle(_ arguments: [String]) -> Bool {
    arguments.dropFirst().first == commandName
  }

  static func run(arguments: [String]) async -> Int {
    do {
      let options = try ModelDownloadOptions(arguments: Array(arguments.dropFirst(2)))
      if options.showHelp {
        print(ModelDownloadOptions.helpText)
        return 0
      }

      try await download(models: options.models)
      return 0
    } catch {
      fputs("error: \(error.localizedDescription)\n", stderr)
      return 1
    }
  }

  private static func download(models: [SpeechModel]) async throws {
    let manager = ModelManager.shared
    manager.loadDownloadedModels()

    for model in models {
      if manager.isDownloaded(model) {
        print("Already downloaded: \(model.rawValue)")
        continue
      }

      print("Downloading: \(model.rawValue)")
      manager.downloadModel(model)
      try await waitForDownload(of: model, manager: manager)
      print("Downloaded: \(model.rawValue)")
    }
  }

  private static func waitForDownload(
    of model: SpeechModel,
    manager: ModelManager
  ) async throws {
    let timeout = Date().addingTimeInterval(modelDownloadTimeoutSeconds(for: model))

    while manager.isDownloading[model, default: false] {
      if let progress = manager.downloadProgress[model] {
        print("Progress \(model.rawValue): \(Int(progress * 100))%")
      }

      if Date() > timeout {
        throw ModelDownloadCommandError.timedOut(model.rawValue)
      }

      try await Task.sleep(nanoseconds: 2_000_000_000)
    }

    manager.loadDownloadedModels()
    guard manager.isDownloaded(model) else {
      throw ModelDownloadCommandError.failed(model.rawValue, manager.downloadError)
    }
  }

  private static func modelDownloadTimeoutSeconds(for model: SpeechModel) -> TimeInterval {
    let minimumTimeout: TimeInterval = 900
    let bytesPerSecond: Double = 2_000_000
    return max(minimumTimeout, Double(model.diskSize) / bytesPerSecond)
  }
}

private struct ModelDownloadOptions {
  static let helpText = """
    Usage:
      Voicey benchmark-download-models MODEL... | --all

    Downloads Voicey models using the app's ModelManager without launching the UI.

    Options:
      --all       Download every SpeechModel case.
      --help      Show this help.
    """

  let models: [SpeechModel]
  let showHelp: Bool

  init(arguments: [String]) throws {
    if arguments.contains("--help") || arguments.contains("-h") {
      self.models = []
      self.showHelp = true
      return
    }

    self.showHelp = false
    if arguments == ["--all"] {
      self.models = SpeechModel.allCases
      return
    }

    guard !arguments.isEmpty else {
      throw ModelDownloadCommandError.requiredModel
    }

    self.models = try arguments.map { argument in
      guard let model = SpeechModel(rawValue: argument) else {
        throw ModelDownloadCommandError.invalidModel(argument)
      }
      return model
    }
  }
}

private enum ModelDownloadCommandError: LocalizedError {
  case failed(String, String?)
  case invalidModel(String)
  case requiredModel
  case timedOut(String)

  var errorDescription: String? {
    switch self {
    case .failed(let model, let reason):
      return "Failed to download \(model): \(reason ?? "unknown error")"
    case .invalidModel(let model):
      return "Unknown model: \(model)"
    case .requiredModel:
      return "Provide at least one model raw value or --all"
    case .timedOut(let model):
      return "Timed out downloading \(model)"
    }
  }
}
