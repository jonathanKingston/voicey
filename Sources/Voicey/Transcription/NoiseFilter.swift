import Foundation

/// Whisper caption / silence artifact cleanup for segmented (benchmark) transcriptions.
///
/// Not used on the Qwen production path (`TranscriptionResult.segments` is empty).
enum NoiseFilter {
  /// Words/phrases that Whisper often outputs for non-speech sounds.
  /// These should be filtered out as they're typically noise artifacts.
  static let noiseWords: Set<String> = [
    // Whisper artifacts for silence
    "...", "…"
  ]

  /// Patterns that indicate noise (regex patterns)
  static let noisePatterns: [String] = [
    "^\\s*\\*[^*]+\\*\\s*$",  // *anything in asterisks*
    "^\\s*\\[[^\\]]+\\]\\s*$",  // [anything in brackets]
    "^\\s*\\([^)]+\\)\\s*$",  // (anything in parentheses) when it's the whole text
    "^\\s*\\.+\\s*$",  // Just dots/ellipsis
    "^\\s*…+\\s*$"  // Just ellipsis character
  ]

  /// Keywords that indicate a bracketed annotation is noise
  static let noiseAnnotationKeywords = [
    "music", "noise", "silence", "inaudible", "unintelligible", "typing",
    "keyboard", "applause"
  ]

  /// Repeated trailing phrases often hallucinated by speech models near silence.
  /// Keep this intentionally conservative to avoid removing legitimate dictated text.
  static let trailingRepeatedArtifactPatterns: [String] = [
    "(?:\\bthank you\\b[\\s,.!?]*){2,}$",
    "(?:\\bthanks\\b[\\s,.!?]*){2,}$",
    "(?:\\bthanks you\\b[\\s,.!?]*){2,}$"
  ]

  /// Check if a bracketed text looks like a noise annotation
  static func isNoiseAnnotation(_ text: String) -> Bool {
    let lowercased = text.lowercased()
    return noiseAnnotationKeywords.contains { lowercased.contains($0) }
  }

  /// Check if entire text matches a noise pattern
  static func matchesNoisePattern(_ text: String) -> Bool {
    for pattern in noisePatterns {
      guard let regex = try? NSRegularExpression(
        pattern: pattern,
        options: .caseInsensitive
      ) else { continue }
      let range = NSRange(text.startIndex..., in: text)
      if regex.firstMatch(in: text, range: range) != nil {
        return true
      }
    }
    return false
  }

  /// Remove repeated hallucinated phrase endings (for example: "thank you thank you").
  static func removeTrailingRepeatedArtifacts(_ text: String) -> String {
    var result = text

    for pattern in trailingRepeatedArtifactPatterns {
      guard let regex = try? NSRegularExpression(
        pattern: pattern,
        options: .caseInsensitive
      ) else { continue }
      result = regex.stringByReplacingMatches(
        in: result,
        range: NSRange(result.startIndex..., in: result),
        withTemplate: ""
      )
    }

    return result.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
