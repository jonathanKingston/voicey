import Foundation

enum CLI {
  static func run() async -> Int32 {
    do {
      let options = try Options(arguments: Array(CommandLine.arguments.dropFirst()))
      if options.showHelp {
        print(Options.helpText)
        return 0
      }

      if options.probeAssets {
        let probe = try await AppleSpeechTranscriber.probeAssets(
          locale: options.locale,
          preset: options.preset
        )
        try printProbeJSON(probe)
        return 0
      }

      let result = try await AppleSpeechTranscriber.transcribe(
        audioURL: options.audioURL,
        locale: options.locale,
        preset: options.preset,
        contextTerms: options.contextTerms,
        warmupCount: options.warmupCount
      )

      if options.outputJSON {
        try printJSON(result)
      } else {
        print(result.text)
      }
      return 0
    } catch {
      fputs("error: \(error.localizedDescription)\n", stderr)
      return 1
    }
  }

  private static func printJSON(_ result: AppleSpeechTranscriptionResult) throws {
    let payload: [String: Any] = [
      "backend": "apple-speech-analyzer",
      "locale": result.localeIdentifier,
      "preset": result.presetName,
      "assetStatus": result.assetStatus,
      "localeInstalled": result.localeInstalled,
      "platformVersion": result.platformVersion,
      "text": result.text,
      "processingSeconds": result.processingSeconds,
      "audioSeconds": result.audioSeconds,
      "realTimeFactor": result.realTimeFactor
    ]
    try printPayload(payload)
  }

  private static func printProbeJSON(_ probe: AppleSpeechAssetProbe) throws {
    let payload: [String: Any] = [
      "backend": "apple-speech-analyzer",
      "mode": "probe-assets",
      "locale": probe.localeIdentifier,
      "resolvedLocale": probe.resolvedLocaleIdentifier,
      "preset": probe.presetName,
      "assetStatus": probe.assetStatus,
      "localeInstalled": probe.localeInstalled,
      "localeSupported": probe.localeSupported,
      "installedLocales": probe.installedLocaleIdentifiers,
      "platformVersion": probe.platformVersion
    ]
    try printPayload(payload)
  }

  private static func printPayload(_ payload: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    guard let json = String(data: data, encoding: .utf8) else {
      throw CLIError.invalidJSONOutput
    }
    print(json)
  }
}

private enum CLIError: LocalizedError {
  case audioFileMissing(String)
  case invalidJSONOutput
  case invalidPreset(String)
  case invalidWarmupCount(String)
  case missingValue(String)
  case requiredArgument(String)
  case unknownArgument(String)

  var errorDescription: String? {
    switch self {
    case .audioFileMissing(let path):
      return "Audio file does not exist: \(path)"
    case .invalidJSONOutput:
      return "Unable to encode JSON output"
    case .invalidPreset(let value):
      return "Unknown preset: \(value). Use offline, live, transcription, or progressiveTranscription."
    case .invalidWarmupCount(let value):
      return "Invalid warmup count: \(value)"
    case .missingValue(let argument):
      return "Missing value for \(argument)"
    case .requiredArgument(let argument):
      return "Missing required argument: \(argument)"
    case .unknownArgument(let argument):
      return "Unknown argument: \(argument)"
    }
  }
}

private struct Options {
  static let helpText = """
    Usage:
      voicey-apple-speech-benchmark --audio PATH [options]
      voicey-apple-speech-benchmark --probe-assets [--locale LOCALE] [--preset PRESET]

    Transcribe one audio file with Apple's SpeechAnalyzer + SpeechTranscriber
    (macOS 26+, offline by default). Intended for WER/RTF comparison against
    Voicey's Qwen benchmark CLIs.

    Options:
      --audio PATH          Audio file readable by AVFoundation.
      --locale LOCALE       BCP-47 locale (default: en-US).
      --preset PRESET       offline/transcription (default) or live/progressiveTranscription.
      --context TERMS       Comma-separated contextual strings (glossary steering eval).
      --warmup N            Untimed runs before the measured transcribe (default: 1).
      --probe-assets        Print installed Speech asset status (no audio required).
      --json                Emit machine-readable JSON on stdout.
      --help                Show this help.
    """

  let audioURL: URL
  let locale: Locale
  let preset: AppleSpeechPreset
  let contextTerms: [String]
  let warmupCount: Int
  let probeAssets: Bool
  let outputJSON: Bool
  let showHelp: Bool

  init(arguments: [String]) throws {
    var audioPath: String?
    var localeIdentifier = "en-US"
    var preset: AppleSpeechPreset = .offline
    var contextTerms: [String] = []
    var warmupCount = 1
    var probeAssets = false
    var outputJSON = false
    var showHelp = false

    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      switch argument {
      case "--audio":
        index += 1
        guard index < arguments.count else { throw CLIError.missingValue(argument) }
        audioPath = arguments[index]
      case "--locale":
        index += 1
        guard index < arguments.count else { throw CLIError.missingValue(argument) }
        localeIdentifier = arguments[index]
      case "--preset":
        index += 1
        guard index < arguments.count else { throw CLIError.missingValue(argument) }
        guard let parsed = AppleSpeechPreset.parse(arguments[index]) else {
          throw CLIError.invalidPreset(arguments[index])
        }
        preset = parsed
      case "--context":
        index += 1
        guard index < arguments.count else { throw CLIError.missingValue(argument) }
        contextTerms = Self.parseContextTerms(arguments[index])
      case "--warmup":
        index += 1
        guard index < arguments.count else { throw CLIError.missingValue(argument) }
        guard let parsed = Int(arguments[index]), parsed >= 0 else {
          throw CLIError.invalidWarmupCount(arguments[index])
        }
        warmupCount = parsed
      case "--probe-assets":
        probeAssets = true
      case "--json":
        outputJSON = true
      case "--help", "-h":
        showHelp = true
      default:
        throw CLIError.unknownArgument(argument)
      }
      index += 1
    }

    self.locale = Locale(identifier: localeIdentifier)
    self.preset = preset
    self.contextTerms = contextTerms
    self.warmupCount = warmupCount
    self.probeAssets = probeAssets
    self.outputJSON = outputJSON
    self.showHelp = showHelp

    if showHelp {
      self.audioURL = URL(fileURLWithPath: "/dev/null")
      return
    }

    if probeAssets {
      self.audioURL = URL(fileURLWithPath: "/dev/null")
      return
    }

    guard let audioPath else { throw CLIError.requiredArgument("--audio") }
    guard FileManager.default.fileExists(atPath: audioPath) else {
      throw CLIError.audioFileMissing(audioPath)
    }
    self.audioURL = URL(fileURLWithPath: audioPath)
  }

  private static func parseContextTerms(_ raw: String) -> [String] {
    raw
      .split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }
}

await CLI.run()
