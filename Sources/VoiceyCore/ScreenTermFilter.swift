import Foundation

/// Filters and tokenizes text for screen-context term selection.
public enum ScreenTermFilter {
  public static let minTokenLength = 2
  public static let maxTokenLength = 64

  private static let stopwords: Set<String> = [
    "a", "an", "and", "are", "as", "at", "be", "but", "by", "for", "from", "had", "has", "have",
    "he", "her", "his", "i", "if", "in", "is", "it", "its", "me", "my", "not", "of", "on", "or",
    "our", "she", "so", "that", "the", "their", "them", "there", "they", "this", "to", "was",
    "we", "were", "what", "when", "which", "who", "will", "with", "you", "your",
  ]

  private static let uiChrome: Set<String> = [
    "about", "add", "back", "cancel", "close", "copy", "cut", "delete", "done", "edit", "file",
    "forward", "help", "home", "menu", "more", "new", "next", "ok", "open", "paste", "preferences",
    "redo", "refresh", "remove", "save", "search", "settings", "share", "stop", "tools", "undo",
    "view", "window", "zoom",
  ]

  /// True when `term` appears in `text` with non-alphanumeric boundaries (not glued across a space).
  public static func appearsWithWordBoundaries(_ term: String, in text: String) -> Bool {
    let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }

    let escaped = NSRegularExpression.escapedPattern(for: trimmed)
    let pattern = #"(?<![A-Za-z0-9])"# + escaped + #"(?![A-Za-z0-9])"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return false }
    let range = NSRange(text.startIndex..., in: text)
    return regex.firstMatch(in: text, range: range) != nil
  }

  public static func tokenize(_ text: String) -> [String] {
    let pattern = #"[A-Za-z0-9][A-Za-z0-9\-_'/]*[A-Za-z0-9]|[A-Za-z0-9]"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

    let range = NSRange(text.startIndex..., in: text)
    var tokens: [String] = []
    regex.enumerateMatches(in: text, range: range) { match, _, _ in
      guard let match, let tokenRange = Range(match.range, in: text) else { return }
      let token = String(text[tokenRange])
      guard token.count >= minTokenLength, token.count <= maxTokenLength else { return }
      let normalized = token.lowercased()
      guard !stopwords.contains(normalized), !uiChrome.contains(normalized) else { return }
      tokens.append(token)
    }
    return tokens
  }

  public static func isNoiseChunk(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count >= 8 else { return true }
    let tokens = tokenize(trimmed)
    return tokens.isEmpty
  }

  /// Drops numeric/log/OCR junk and generic tokens from decoder steering glossaries.
  public static func isSteeringNoiseToken(_ token: String) -> Bool {
    let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return true }

    if trimmed.count <= 2 {
      return true
    }

    let lower = trimmed.lowercased()
    if stopwords.contains(lower) || uiChrome.contains(lower) {
      return true
    }

    if trimmed.allSatisfy(\.isNumber) {
      return true
    }

    if trimmed.count >= 5, trimmed.allSatisfy({ $0.isHexDigit }) {
      return true
    }

    if trimmed.range(of: #"\d{4,}"#, options: .regularExpression) != nil {
      let letterCount = trimmed.filter(\.isLetter).count
      let digitCount = trimmed.filter(\.isNumber).count
      if digitCount >= 4, letterCount > 0, letterCount <= 12 {
        return true
      }
    }

    let pathFragments: Set<String> = ["tmp", "usr", "bin", "private", "var", "predicate", "subsystem"]
    if pathFragments.contains(lower) {
      return true
    }

    if lower.hasPrefix("voicey"), trimmed.filter(\.isNumber).count >= 3 {
      return true
    }

    if isDateOrTimeToken(trimmed) {
      return true
    }

    return false
  }

  public static func isDateOrTimeToken(_ token: String) -> Bool {
    if token.range(of: #"\d{4}-\d{1,2}-\d{1,2}"#, options: .regularExpression) != nil {
      return true
    }
    if token.range(of: #"\d{1,2}:\d{2}(:\d{2})?"#, options: .regularExpression) != nil {
      return true
    }
    if token.range(of: #"^\d{4}$"#, options: .regularExpression) != nil {
      return true
    }
    if token.allSatisfy({ $0.isNumber || $0 == "-" || $0 == ":" || $0 == "/" }) {
      return true
    }
    return false
  }
}
