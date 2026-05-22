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
}
