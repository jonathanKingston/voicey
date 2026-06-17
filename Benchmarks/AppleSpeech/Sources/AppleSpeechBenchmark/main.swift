import Foundation
import Speech

enum CLIError: Error, CustomStringConvertible {
  case missingArgument(String)
  case speechUnavailable
  case speechUnauthorized
  case emptyTranscript(URL)
  case invalidTSV(String)

  var description: String {
    switch self {
    case .missingArgument(let flag):
      return "Missing value for \(flag)"
    case .speechUnavailable:
      return "Speech recognition is unavailable for en-US"
    case .speechUnauthorized:
      return "Speech recognition not authorized — enable in System Settings → Privacy → Speech Recognition"
    case .emptyTranscript(let url):
      return "Empty transcript for \(url.path)"
    case .invalidTSV(let message):
      return message
    }
  }
}

struct BatchSample {
  let relativePath: String
  let audioURL: URL
}

@main
struct AppleSpeechBenchmark {
  static func main() async {
    do {
      try await run()
    } catch {
      fputs("error: \(error)\n", stderr)
      exit(1)
    }
  }

  static func run() async throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.contains(where: { $0 == "--help" || $0 == "-h" }) {
      print(helpText)
      return
    }

    let outputURL = try outputFileURL(from: arguments)
    let emit: (String) -> Void = { line in
      if let outputURL {
        let handle = try? FileHandle(forWritingTo: outputURL)
        if handle == nil {
          FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        }
        let writer = try? FileHandle(forWritingTo: outputURL)
        writer?.seekToEndOfFile()
        writer?.write(Data((line + "\n").utf8))
        try? writer?.close()
      } else {
        print(line)
      }
    }

    try await ensureSpeechAuthorized()

    if let wavIndex = arguments.firstIndex(of: "--wav"), wavIndex + 1 < arguments.count {
      let url = URL(fileURLWithPath: arguments[wavIndex + 1])
      let text = try await transcribeFile(url)
      emit(text)
      return
    }

    guard
      let tsvIndex = arguments.firstIndex(of: "--tsv"),
      tsvIndex + 1 < arguments.count,
      let clipsIndex = arguments.firstIndex(of: "--clips-dir"),
      clipsIndex + 1 < arguments.count
    else {
      throw CLIError.missingArgument("--tsv / --clips-dir (or --wav)")
    }

    if let outputURL, FileManager.default.fileExists(atPath: outputURL.path) {
      try FileManager.default.removeItem(at: outputURL)
    }

    let tsvURL = URL(fileURLWithPath: arguments[tsvIndex + 1])
    let clipsDirectory = URL(fileURLWithPath: arguments[clipsIndex + 1])
    let samples = try loadSamples(tsvURL: tsvURL, clipsDirectory: clipsDirectory)

    for sample in samples {
      let started = Date()
      let text = try await transcribeFile(sample.audioURL)
      let elapsed = Date().timeIntervalSince(started)
      let payload: [String: Any] = [
        "audio": sample.relativePath,
        "text": text,
        "processingSeconds": elapsed,
      ]
      let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
      emit(String(decoding: data, as: UTF8.self))
    }
  }

  static func outputFileURL(from arguments: [String]) throws -> URL? {
    guard let index = arguments.firstIndex(of: "--output") else {
      return nil
    }
    guard index + 1 < arguments.count else {
      throw CLIError.missingArgument("--output")
    }
    return URL(fileURLWithPath: arguments[index + 1])
  }

  static let helpText = """
  voicey-apple-speech-benchmark — offline Apple Speech transcription for eval

  Usage:
    voicey-apple-speech-benchmark --wav PATH
    voicey-apple-speech-benchmark --tsv PATH --clips-dir PATH [--output PATH]

  Prints plain text for --wav, or JSON lines for batch mode.
  Use --output when launching via the .app bundle (see README).
  """

  static func ensureSpeechAuthorized() async throws {
    let status = await withCheckedContinuation { continuation in
      SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
    }
    guard status == .authorized else {
      throw CLIError.speechUnauthorized
    }
  }

  static func transcribeFile(_ url: URL) async throws -> String {
    guard
      let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
      recognizer.isAvailable
    else {
      throw CLIError.speechUnavailable
    }

    let request = SFSpeechURLRecognitionRequest(url: url)
    request.shouldReportPartialResults = false

    return try await withCheckedThrowingContinuation { continuation in
      recognizer.recognitionTask(with: request) { result, error in
        if let error {
          continuation.resume(throwing: error)
          return
        }
        guard let result, result.isFinal else {
          return
        }
        let text = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
          continuation.resume(throwing: CLIError.emptyTranscript(url))
          return
        }
        continuation.resume(returning: text)
      }
    }
  }

  static func loadSamples(tsvURL: URL, clipsDirectory: URL) throws -> [BatchSample] {
    let raw = try String(contentsOf: tsvURL, encoding: .utf8)
    var lines = raw.split(whereSeparator: \.isNewline).map(String.init)
    guard let headerLine = lines.first else {
      throw CLIError.invalidTSV("TSV is empty")
    }
    lines.removeFirst()

    let headers = headerLine.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
    guard let pathIndex = headers.firstIndex(of: "path") else {
      throw CLIError.invalidTSV("TSV missing path column")
    }

    return try lines.compactMap { line in
      let columns = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
      guard pathIndex < columns.count else { return nil }
      let relativePath = columns[pathIndex].trimmingCharacters(in: .whitespacesAndNewlines)
      guard !relativePath.isEmpty else { return nil }
      let audioURL = clipsDirectory.appendingPathComponent(relativePath)
      guard FileManager.default.fileExists(atPath: audioURL.path) else {
        throw CLIError.invalidTSV("Missing clip: \(audioURL.path)")
      }
      return BatchSample(relativePath: relativePath, audioURL: audioURL)
    }
  }
}
