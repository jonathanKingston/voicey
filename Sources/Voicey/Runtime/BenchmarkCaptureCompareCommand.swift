import Foundation

enum BenchmarkCaptureCompareCommand {
  private static let commandName = "benchmark-capture-compare"

  static func canHandle(_ arguments: [String]) -> Bool {
    arguments.dropFirst().first == commandName
  }

  static func run(arguments: [String]) async -> Int {
    do {
      let options = try Options(arguments: Array(arguments.dropFirst(2)))
      if options.showHelp {
        print(Options.helpText)
        return 0
      }

      try BenchmarkRustRequirements.requireCapture()

      guard let capturePath = VoiceyRuntimeConfiguration.captureWorkerPath else {
        fputs("error: voicey-capture binary not found\n", stderr)
        return 1
      }

      let rustClient = VoiceyCaptureWorkerClient(path: capturePath)
      let rustFixture = try rustClient.recordFixture(durationSeconds: options.durationSeconds)
      defer { PCMBufferHandle(shmName: rustFixture.shmName, sampleCount: rustFixture.sampleCount, sampleRate: rustFixture.sampleRate).remove() }

      let expectedSamples = Int(options.durationSeconds * 16_000.0)
      let payload: [String: Any] = [
        "rustSampleCount": rustFixture.sampleCount,
        "expectedSampleCount": expectedSamples,
        "sampleRate": rustFixture.sampleRate,
        "durationSeconds": options.durationSeconds,
        "nonZeroSamples": rustFixture.nonZeroSampleCount
      ]
      let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
      guard let json = String(data: data, encoding: .utf8) else {
        throw BenchmarkCaptureCompareError.invalidJSON
      }
      print(json)

      let withinTolerance = abs(rustFixture.sampleCount - expectedSamples) <= Int(Float(expectedSamples) * 0.15)
      return withinTolerance ? 0 : 2
    } catch {
      fputs("error: \(error.localizedDescription)\n", stderr)
      return 1
    }
  }
}

private struct Options {
  static let helpText = """
    Usage:
      Voicey benchmark-capture-compare [--duration SECONDS]

    Smoke-tests voicey-capture fixture recording (Rust-only; no Swift AVAudioEngine path).
    """

  let durationSeconds: Double
  let showHelp: Bool

  init(arguments: [String]) throws {
    var durationSeconds = 0.25
    var showHelp = false
    var index = 0
    while index < arguments.count {
      switch arguments[index] {
      case "--duration":
        index += 1
        guard index < arguments.count, let value = Double(arguments[index]) else {
          throw BenchmarkCaptureCompareError.missingValue("--duration")
        }
        durationSeconds = value
      case "--help", "-h":
        showHelp = true
      default:
        throw BenchmarkCaptureCompareError.unknownArgument(arguments[index])
      }
      index += 1
    }
    self.durationSeconds = durationSeconds
    self.showHelp = showHelp
  }
}

enum BenchmarkCaptureCompareError: LocalizedError {
  case missingValue(String)
  case unknownArgument(String)
  case invalidJSON

  var errorDescription: String? {
    switch self {
    case .missingValue(let argument):
      return "Missing value for \(argument)"
    case .unknownArgument(let argument):
      return "Unknown argument: \(argument)"
    case .invalidJSON:
      return "Failed to encode benchmark output as UTF-8 JSON"
    }
  }
}
