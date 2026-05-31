import Foundation

/// Whisper caption / silence artifact cleanup for segmented (benchmark) transcriptions.
///
/// Not used on the Qwen production path (empty segment list).
public enum NoiseFilter {
  /// Words/phrases that Whisper often outputs for non-speech sounds.
  public static let noiseWords: Set<String> = [
    "...", "…",
  ]

  public static let noisePatterns: [String] = [
    "^\\s*\\*[^*]+\\*\\s*$",
    "^\\s*\\[[^\\]]+\\]\\s*$",
    "^\\s*\\([^)]+\\)\\s*$",
    "^\\s*\\.+\\s*$",
    "^\\s*…+\\s*$",
  ]

  public static let noiseAnnotationKeywords = [
    "music", "noise", "silence", "inaudible", "unintelligible", "typing",
    "keyboard", "applause",
  ]

  public static let trailingRepeatedArtifactPatterns: [String] = [
    "(?:\\bthank you\\b[\\s,.!?]*){2,}$",
    "(?:\\bthanks\\b[\\s,.!?]*){2,}$",
    "(?:\\bthanks you\\b[\\s,.!?]*){2,}$",
  ]

  public static func isNoiseAnnotation(_ text: String) -> Bool {
    let lowercased = text.lowercased()
    return noiseAnnotationKeywords.contains { lowercased.contains($0) }
  }

  public static func matchesNoisePattern(_ text: String) -> Bool {
    for pattern in noisePatterns {
      guard
        let regex = try? NSRegularExpression(
          pattern: pattern,
          options: .caseInsensitive
        )
      else { continue }
      let range = NSRange(text.startIndex..., in: text)
      if regex.firstMatch(in: text, range: range) != nil {
        return true
      }
    }
    return false
  }

  public static func removeTrailingRepeatedArtifacts(_ text: String) -> String {
    var result = text

    for pattern in trailingRepeatedArtifactPatterns {
      guard
        let regex = try? NSRegularExpression(
          pattern: pattern,
          options: .caseInsensitive
        )
      else { continue }
      result = regex.stringByReplacingMatches(
        in: result,
        range: NSRange(result.startIndex..., in: result),
        withTemplate: ""
      )
    }

    return result.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
