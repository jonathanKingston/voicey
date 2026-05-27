import AVFoundation
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

      guard let capturePath = VoiceyRuntimeConfiguration.captureWorkerPath else {
        fputs("error: voicey-capture binary not found\n", stderr)
        return 1
      }

      let manager = AudioCaptureManager()
      manager.startCapture()
      try await Task.sleep(nanoseconds: UInt64(options.durationSeconds * 1_000_000_000))
      guard let swiftSamples = manager.stopCapture(applyTrailingTrimHeuristic: false) else {
        fputs("error: Swift capture returned no samples\n", stderr)
        return 1
      }

      let rustClient = VoiceyCaptureWorkerClient(path: capturePath)
      let rustFixture = try rustClient.recordFixture(durationSeconds: options.durationSeconds)
      let rustSamples = try SharedMemoryPCM.read(
        name: rustFixture.shmName,
        sampleCount: rustFixture.sampleCount
      )
      defer { SharedMemoryPCM.remove(name: rustFixture.shmName) }

      let compared = min(swiftSamples.count, rustSamples.count)
      var maxDelta: Float = 0
      for index in 0..<compared {
        maxDelta = max(maxDelta, abs(swiftSamples[index] - rustSamples[index]))
      }

      let payload: [String: Any] = [
        "swiftSampleCount": swiftSamples.count,
        "rustSampleCount": rustSamples.count,
        "comparedSamples": compared,
        "maxAbsDelta": maxDelta,
        "durationSeconds": options.durationSeconds
      ]
      let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
      guard let json = String(data: data, encoding: .utf8) else {
        throw BenchmarkCaptureCompareError.invalidJSON
      }
      print(json)
      return maxDelta <= options.tolerance ? 0 : 2
    } catch {
      fputs("error: \(error.localizedDescription)\n", stderr)
      return 1
    }
  }
}

private struct Options {
  static let helpText = """
    Usage:
      Voicey benchmark-capture-compare [--duration SECONDS] [--tolerance DELTA]

    Compares Swift AudioCaptureManager samples with voicey-capture fixture output.
    """

  let durationSeconds: Double
  let tolerance: Float
  let showHelp: Bool

  init(arguments: [String]) throws {
    var durationSeconds = 0.25
    var tolerance: Float = 0.05
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
      case "--tolerance":
        index += 1
        guard index < arguments.count, let value = Float(arguments[index]) else {
          throw BenchmarkCaptureCompareError.missingValue("--tolerance")
        }
        tolerance = value
      case "--help", "-h":
        showHelp = true
      default:
        throw BenchmarkCaptureCompareError.unknownArgument(arguments[index])
      }
      index += 1
    }
    self.durationSeconds = durationSeconds
    self.tolerance = tolerance
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
