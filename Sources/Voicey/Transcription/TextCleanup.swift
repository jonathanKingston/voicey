import Foundation

/// Utilities for text cleanup and formatting in transcription output
enum TextCleanup {
  /// Default text expansions for common spoken phrases
  static let defaultTextExpansions: [String: String] = [
    "etcetera": "etc.",
    "et cetera": "etc.",
    "for example": "e.g.",
    "that is": "i.e.",
    "versus": "vs.",
    "mister": "Mr.",
    "missus": "Mrs.",
    "doctor": "Dr.",
    "okay": "OK",
    "o k": "OK"
  ]

  /// Capitalize the first character of a string
  static func capitalizeFirst(_ text: String) -> String {
    guard let first = text.first else { return text }
    return first.uppercased() + text.dropFirst()
  }

  /// Check if text starts with a conjunction
  static func isConjunction(_ text: String) -> Bool {
    let conjunctions = [
      "and", "but", "or", "so", "yet", "for", "nor",
      "because", "although", "while", "if", "when"
    ]
    let firstWord = text.lowercased().split(separator: " ").first.map(String.init) ?? ""
    return conjunctions.contains(firstWord)
  }

  /// Apply text expansions to convert spoken phrases to written form
  static func applyExpansions(_ text: String, expansions: [String: String]) -> String {
    var result = text

    for (spoken, written) in expansions {
      let pattern = "\\b\(NSRegularExpression.escapedPattern(for: spoken))\\b"
      guard let regex = try? NSRegularExpression(
        pattern: pattern,
        options: .caseInsensitive
      ) else { continue }
      result = regex.stringByReplacingMatches(
        in: result,
        range: NSRange(result.startIndex..., in: result),
        withTemplate: written
      )
    }

    return result
  }

  /// Ensure "I" is always capitalized
  static func capitalizeI(_ text: String) -> String {
    var result = text
    result = result.replacingOccurrences(of: " i ", with: " I ")
    result = result.replacingOccurrences(of: " i'", with: " I'")
    if result.hasPrefix("i ") {
      result = "I" + result.dropFirst()
    }
    return result
  }

  /// Clean up spacing and punctuation issues
  static func cleanupSpacingAndPunctuation(_ text: String) -> String {
    var result = text

    // Fix multiple spaces
    while result.contains("  ") {
      result = result.replacingOccurrences(of: "  ", with: " ")
    }

    // Fix space before punctuation
    result = result.replacingOccurrences(of: " .", with: ".")
    result = result.replacingOccurrences(of: " ,", with: ",")
    result = result.replacingOccurrences(of: " ?", with: "?")
    result = result.replacingOccurrences(of: " !", with: "!")

    // Fix multiple punctuation
    result = result.replacingOccurrences(of: "..", with: ".")
    result = result.replacingOccurrences(of: ",,", with: ",")
    result = result.replacingOccurrences(of: "....", with: "...")

    // Ensure space after punctuation
    let punctuationPattern = "([.!?,])([A-Za-z])"
    if let regex = try? NSRegularExpression(pattern: punctuationPattern) {
      result = regex.stringByReplacingMatches(
        in: result,
        range: NSRange(result.startIndex..., in: result),
        withTemplate: "$1 $2"
      )
    }

    return result.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
