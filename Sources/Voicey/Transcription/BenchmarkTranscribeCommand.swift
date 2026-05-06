import AVFoundation
import Darwin
import Foundation

enum BenchmarkTranscribeCommand {
  private static let commandName = "benchmark-transcribe"

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

      let samples = try AudioFileSamples.load16kMonoFloatSamples(from: options.audioURL)
      let result = try await withStdoutRedirectedToStderr {
        try await transcribe(samples: samples, model: options.model)
      }
      let text = options.postProcess ? PostProcessor().process(result) : result.text

      if options.outputJSON {
        try printJSON(result: result, text: text, model: options.model, audioURL: options.audioURL)
      } else {
        print(text)
      }
      return 0
    } catch {
      fputs("error: \(error.localizedDescription)\n", stderr)
      return 1
    }
  }

  private static func transcribe(samples: [Float], model: SpeechModel) async throws -> TranscriptionResult {
    SettingsManager.shared.selectedModel = model

    switch model.backendKind {
    case .whisperKit:
      let engine = WhisperEngine()
      try await engine.loadModel(variant: model.rawValue)
      return try await engine.transcribe(audioBuffer: samples)
    case .qwenMLX:
      let engine = QwenEngine()
      try await engine.loadModel(variant: model.rawValue)
      return try await engine.transcribe(audioBuffer: samples)
    case .granitePython:
      let engine = GraniteEngine()
      try await engine.loadModel(variant: model.rawValue)
      return try await engine.transcribe(audioBuffer: samples)
    }
  }

  static func withStdoutRedirectedToStderr<T>(
    _ operation: () async throws -> T
  ) async throws -> T {
    let originalStdout = dup(STDOUT_FILENO)
    guard originalStdout >= 0 else {
      throw BenchmarkTranscribeError.stdoutRedirectionFailed
    }

    fflush(stdout)
    guard dup2(STDERR_FILENO, STDOUT_FILENO) >= 0 else {
      close(originalStdout)
      throw BenchmarkTranscribeError.stdoutRedirectionFailed
    }

    do {
      let result = try await operation()
      fflush(stdout)
      dup2(originalStdout, STDOUT_FILENO)
      close(originalStdout)
      return result
    } catch {
      fflush(stdout)
      dup2(originalStdout, STDOUT_FILENO)
      close(originalStdout)
      throw error
    }
  }

  private static func printJSON(
    result: TranscriptionResult,
    text: String,
    model: SpeechModel,
    audioURL: URL
  ) throws {
    let payload: [String: Any] = [
      "audio": audioURL.path,
      "model": model.rawValue,
      "text": text,
      "rawText": result.text,
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
      Voicey benchmark-transcribe --model MODEL --audio PATH [--json] [--post-process]

    Runs a single audio file through Voicey's real model wrapper code without launching the app UI.

    Options:
      --model MODEL       SpeechModel raw value, for example qwen3-asr-0.6b-6bit or large-v3_turbo.
      --audio PATH        Audio file readable by AVFoundation. It is converted to 16 kHz mono float samples.
      --json              Print a single JSON object instead of plain transcript text.
      --post-process      Apply Voicey's PostProcessor before printing text.
      --help              Show this help.
    """

  let model: SpeechModel
  let audioURL: URL
  let outputJSON: Bool
  let postProcess: Bool
  let showHelp: Bool

  init(arguments: [String]) throws {
    var state = OptionsState()

    var index = 0
    while index < arguments.count {
      try Self.apply(arguments: arguments, index: &index, state: &state)
      index += 1
    }

    self.outputJSON = state.outputJSON
    self.postProcess = state.postProcess
    self.showHelp = state.showHelp

    if state.showHelp {
      self.model = ModelManager.defaultModel
      self.audioURL = URL(fileURLWithPath: "/dev/null")
      return
    }

    guard let model = state.model else { throw BenchmarkTranscribeError.requiredArgument("--model") }
    guard let audioURL = state.audioURL else { throw BenchmarkTranscribeError.requiredArgument("--audio") }
    guard FileManager.default.fileExists(atPath: audioURL.path) else {
      throw BenchmarkTranscribeError.audioFileMissing(audioURL.path)
    }

    self.model = model
    self.audioURL = audioURL
  }

  private static func apply(
    arguments: [String],
    index: inout Int,
    state: inout OptionsState
  ) throws {
    let argument = arguments[index]
    switch argument {
    case "--model":
      state.model = try modelValue(after: argument, arguments: arguments, index: &index)
    case "--audio":
      state.audioURL = URL(fileURLWithPath: try value(after: argument, arguments: arguments, index: &index))
    case "--json":
      state.outputJSON = true
    case "--post-process":
      state.postProcess = true
    case "--help", "-h":
      state.showHelp = true
    default:
      throw BenchmarkTranscribeError.unknownArgument(argument)
    }
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

private struct OptionsState {
  var model: SpeechModel?
  var audioURL: URL?
  var outputJSON = false
  var postProcess = false
  var showHelp = false
}

enum AudioFileSamples {
  private static let targetSampleRate = 16_000.0

  static func load16kMonoFloatSamples(from url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let inputFormat = file.processingFormat
    let outputFormat = try makeOutputFormat()
    let inputBuffer = try readInputBuffer(from: file, format: inputFormat)
    let outputBuffer = try convert(inputBuffer: inputBuffer, to: outputFormat)

    guard let channelData = outputBuffer.floatChannelData else {
      throw BenchmarkTranscribeError.audioConversionFailed
    }

    return Array(UnsafeBufferPointer(start: channelData[0], count: Int(outputBuffer.frameLength)))
  }

  private static func makeOutputFormat() throws -> AVAudioFormat {
    guard let outputFormat = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: targetSampleRate,
      channels: 1,
      interleaved: false
    ) else {
      throw BenchmarkTranscribeError.unsupportedAudioFormat
    }
    return outputFormat
  }

  private static func readInputBuffer(
    from file: AVAudioFile,
    format: AVAudioFormat
  ) throws -> AVAudioPCMBuffer {
    guard let inputBuffer = AVAudioPCMBuffer(
      pcmFormat: format,
      frameCapacity: AVAudioFrameCount(file.length)
    ) else {
      throw BenchmarkTranscribeError.audioBufferAllocationFailed
    }

    try file.read(into: inputBuffer)
    guard inputBuffer.frameLength > 0 else {
      throw BenchmarkTranscribeError.emptyAudio
    }
    return inputBuffer
  }

  private static func convert(
    inputBuffer: AVAudioPCMBuffer,
    to outputFormat: AVAudioFormat
  ) throws -> AVAudioPCMBuffer {
    guard let converter = AVAudioConverter(from: inputBuffer.format, to: outputFormat) else {
      throw BenchmarkTranscribeError.unsupportedAudioFormat
    }

    let outputCapacity = AVAudioFrameCount(
      ceil(Double(inputBuffer.frameLength) * outputFormat.sampleRate / inputBuffer.format.sampleRate)
    ) + 1
    guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity) else {
      throw BenchmarkTranscribeError.audioBufferAllocationFailed
    }

    var didProvideInput = false
    var conversionError: NSError?
    let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outputStatus in
      if didProvideInput {
        outputStatus.pointee = .noDataNow
        return nil
      }

      didProvideInput = true
      outputStatus.pointee = .haveData
      return inputBuffer
    }

    if let conversionError {
      throw conversionError
    }
    guard status != .error else {
      throw BenchmarkTranscribeError.audioConversionFailed
    }
    return outputBuffer
  }
}

enum BenchmarkTranscribeError: LocalizedError {
  case audioBufferAllocationFailed
  case audioConversionFailed
  case audioFileMissing(String)
  case emptyAudio
  case emptyTSV
  case invalidJSONOutput
  case invalidModel(String)
  case missingValue(String)
  case requiredColumn(String)
  case requiredArgument(String)
  case stdoutRedirectionFailed
  case unknownArgument(String)
  case unsupportedAudioFormat

  var errorDescription: String? {
    switch self {
    case .audioBufferAllocationFailed:
      return "Unable to allocate an audio buffer"
    case .audioConversionFailed:
      return "Unable to convert audio to 16 kHz mono float samples"
    case .audioFileMissing(let path):
      return "Audio file does not exist: \(path)"
    case .emptyAudio:
      return "Audio file contains no readable samples"
    case .emptyTSV:
      return "TSV file is empty"
    case .invalidJSONOutput:
      return "Unable to encode JSON output"
    case .invalidModel(let model):
      return "Unknown model: \(model)"
    case .missingValue(let argument):
      return "Missing value for \(argument)"
    case .requiredColumn(let column):
      return "TSV file is missing required column: \(column)"
    case .requiredArgument(let argument):
      return "Missing required argument: \(argument)"
    case .stdoutRedirectionFailed:
      return "Unable to reserve stdout for benchmark output"
    case .unknownArgument(let argument):
      return "Unknown argument: \(argument)"
    case .unsupportedAudioFormat:
      return "Unsupported audio format"
    }
  }
}
