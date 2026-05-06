import Foundation

enum BenchmarkIncrementalBatchCommand {
  private static let commandName = "benchmark-transcribe-incremental-batch"

  static func canHandle(_ arguments: [String]) -> Bool {
    arguments.dropFirst().first == commandName
  }

  static func run(arguments: [String]) async -> Int {
    RuntimeOutputMode.reservesStdoutForMachineReadableOutput = true

    do {
      let options = try Options(arguments: Array(arguments.dropFirst(2)))
      if options.showHelp {
        print(Options.helpText)
        return 0
      }

      let samples = try BenchmarkBatchSample.load(
        tsvURL: options.tsvURL,
        clipsDirectory: options.clipsDirectory
      )
      try await transcribe(samples: samples, model: options.model)
      return 0
    } catch {
      fputs("error: \(error.localizedDescription)\n", stderr)
      return 1
    }
  }

  private static func transcribe(samples: [BenchmarkBatchSample], model: SpeechModel) async throws {
    SettingsManager.shared.selectedModel = model

    switch model.backendKind {
    case .whisperKit:
      let engine = WhisperEngine()
      try await BenchmarkTranscribeCommand.withStdoutRedirectedToStderr {
        try await engine.loadModel(variant: model.rawValue)
      }
      try await transcribe(samples: samples, model: model) { audioBuffer in
        try await engine.transcribe(audioBuffer: audioBuffer)
      }
    case .qwenMLX:
      let engine = QwenEngine()
      try await BenchmarkTranscribeCommand.withStdoutRedirectedToStderr {
        try await engine.loadModel(variant: model.rawValue)
      }
      try await transcribe(samples: samples, model: model) { audioBuffer in
        try await engine.transcribe(audioBuffer: audioBuffer)
      }
    case .granitePython:
      let engine = GraniteEngine()
      try await BenchmarkTranscribeCommand.withStdoutRedirectedToStderr {
        try await engine.loadModel(variant: model.rawValue)
      }
      try await transcribe(samples: samples, model: model) { audioBuffer in
        try await engine.transcribe(audioBuffer: audioBuffer)
      }
    }
  }

  private static func transcribe(
    samples: [BenchmarkBatchSample],
    model: SpeechModel,
    transcribeChunk: @escaping ([Float]) async throws -> TranscriptionResult
  ) async throws {
    for sample in samples {
      let result = try await BenchmarkTranscribeCommand.withStdoutRedirectedToStderr {
        try await BenchmarkIncrementalTranscription.transcribe(
          samples: sample.audioSamples(),
          applyTrailingTrimHeuristic: !model.isGraniteModel,
          transcribeChunk: transcribeChunk
        )
      }
      try printBatchJSON(result: result, sample: sample, model: model)
    }
  }

  private static func printBatchJSON(
    result: TranscriptionResult,
    sample: BenchmarkBatchSample,
    model: SpeechModel
  ) throws {
    let payload: [String: Any] = [
      "audio": sample.relativeAudioPath,
      "model": model.rawValue,
      "mode": "incremental",
      "text": result.text,
      "language": result.language,
      "processingSeconds": result.processingTime,
      "audioSeconds": result.performanceMetrics.audioDuration,
      "realTimeFactor": result.performanceMetrics.realTimeFactor
    ]
    let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    guard let json = String(data: data, encoding: .utf8) else {
      throw BenchmarkTranscribeError.invalidJSONOutput
    }
    print(json)
  }
}

private struct Options {
  static let helpText = """
    Usage:
      Voicey benchmark-transcribe-incremental-batch --model MODEL --tsv PATH --clips-dir DIR

    Loads one Voicey model once, then simulates Voicey's pause-based piecemeal
    transcription over every row in the TSV.
    """

  let model: SpeechModel
  let tsvURL: URL
  let clipsDirectory: URL
  let showHelp: Bool

  init(arguments: [String]) throws {
    var model: SpeechModel?
    var tsvURL: URL?
    var clipsDirectory: URL?
    var showHelp = false

    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      switch argument {
      case "--model":
        model = try Self.modelValue(after: argument, arguments: arguments, index: &index)
      case "--tsv":
        tsvURL = URL(fileURLWithPath: try Self.value(after: argument, arguments: arguments, index: &index))
      case "--clips-dir":
        clipsDirectory = URL(fileURLWithPath: try Self.value(after: argument, arguments: arguments, index: &index))
      case "--help", "-h":
        showHelp = true
      default:
        throw BenchmarkTranscribeError.unknownArgument(argument)
      }
      index += 1
    }

    self.showHelp = showHelp
    if showHelp {
      self.model = ModelManager.defaultModel
      self.tsvURL = URL(fileURLWithPath: "/dev/null")
      self.clipsDirectory = URL(fileURLWithPath: "/dev/null")
      return
    }

    guard let model else { throw BenchmarkTranscribeError.requiredArgument("--model") }
    guard let tsvURL else { throw BenchmarkTranscribeError.requiredArgument("--tsv") }
    guard let clipsDirectory else { throw BenchmarkTranscribeError.requiredArgument("--clips-dir") }
    self.model = model
    self.tsvURL = tsvURL
    self.clipsDirectory = clipsDirectory
  }

  private static func value(
    after argument: String,
    arguments: [String],
    index: inout Int
  ) throws -> String {
    index += 1
    guard index < arguments.count else { throw BenchmarkTranscribeError.missingValue(argument) }
    return arguments[index]
  }

  private static func modelValue(
    after argument: String,
    arguments: [String],
    index: inout Int
  ) throws -> SpeechModel {
    let rawModel = try value(after: argument, arguments: arguments, index: &index)
    guard let model = SpeechModel(rawValue: rawModel) else {
      throw BenchmarkTranscribeError.invalidModel(rawModel)
    }
    return model
  }
}
