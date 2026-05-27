import Foundation

/// Cleans Vision OCR lines/tokens before screen steering (drops log-like UI and numeric artifacts).
public enum ScreenContextOCRTextFilter {
  private static let logLineMarkers = [
    "ScreenContextCollector:",
    "ScreenContext exposure:",
    "ScreenContextOCR:",
    "processTranscription:",
    "PostProcessor:",
    "QwenEngine:",
    "Steering:",
    "Steering terms:",
    "work.voicey.VoiceyDirect",
    "Filtering the log data",
    "Timestamp",
    "composedMessage",
    "/usr/bin/log",
    "tmp/voicey",
    "predicate 'subsystem"
  ]

  public static func filteredRecognizedLines(_ lines: [String]) -> [String] {
    let joined = joinContinuationLines(lines)
    return joined
      .map { sanitizeLine($0) }
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .filter { !isNoiseLine($0) }
  }

  /// Joins OCR lines that Vision split mid-word or mid-phrase (lowercase follow-on).
  public static func joinContinuationLines(_ lines: [String]) -> [String] {
    var result: [String] = []
    var buffer = ""

    for line in lines {
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { continue }

      if buffer.isEmpty {
        buffer = trimmed
        continue
      }

      if shouldJoinContinuation(previous: buffer, next: trimmed) {
        let glue = continuationGlue(previous: buffer, next: trimmed)
        buffer += glue + trimmed
      } else {
        result.append(buffer)
        buffer = trimmed
      }
    }

    if !buffer.isEmpty {
      result.append(buffer)
    }
    return result
  }

  private static func shouldJoinContinuation(previous: String, next: String) -> Bool {
    guard let last = previous.last, let first = next.first else { return false }
    if ".!?".contains(last) { return false }
    if first.isLowercase { return true }
    if last.isLetter, first.isLetter, last.isLowercase, !first.isUppercase {
      return true
    }
    return false
  }

  private static func continuationGlue(previous: String, next: String) -> String {
    " "
  }

  public static func isNoiseLine(_ line: String) -> Bool {
    let lower = line.lowercased()
    if logLineMarkers.contains(where: { lower.contains($0.lowercased()) }) {
      return true
    }
    if line.hasPrefix("[") && line.contains("]") && lower.contains("transcription") {
      return true
    }
    return false
  }

  public static func sanitizeLine(_ line: String) -> String {
    var result = line
    result = replacingMatches(in: result, pattern: #"\d{4}-\d{1,2}-\d{1,2}(?:[ T]\d{1,2}:\d{2}(?::\d{2})?)?"#, with: " ")
    result = replacingMatches(in: result, pattern: #"\b\d{1,2}:\d{2}(:\d{2})?\b"#, with: " ")
    result = replacingMatches(in: result, pattern: #"\b\d{4}\b"#, with: " ")
    result = replacingMatches(in: result, pattern: #"\b0x[0-9a-fA-F]+\b"#, with: " ")
    result = replacingMatches(in: result, pattern: #"\s{2,}"#, with: " ")
    return result.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public static func isSteeringNoiseToken(_ token: String) -> Bool {
    ScreenTermFilter.isSteeringNoiseToken(token)
  }

  private static func replacingMatches(in text: String, pattern: String, with replacement: String) -> String {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
    let range = NSRange(text.startIndex..., in: text)
    return regex.stringByReplacingMatches(in: text, range: range, withTemplate: replacement)
  }
}
