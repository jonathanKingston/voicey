import Foundation

/// Builds decoder context strings for Qwen3 ASR vocabulary biasing.
public enum TranscriptionGlossary {
  /// Upper bound on glossary context length passed to the model.
  public static let maxContextCharacterCount = 2000

  /// Returns decoder context when enabled and the glossary contains terms.
  public static func decodingContext(enabled: Bool, rawGlossary: String) -> String? {
    guard enabled else { return nil }
    let formatted = format(rawGlossary)
    return formatted.isEmpty ? nil : formatted
  }

  /// Normalizes user glossary text into a Qwen decoder context prefix.
  public static func format(_ raw: String) -> String {
    let terms = parseTerms(raw)
    guard !terms.isEmpty else { return "" }

    let joined = terms.joined(separator: ", ")
    let body = "Glossary: \(joined)"
    guard body.count <= maxContextCharacterCount else {
      return String(body.prefix(maxContextCharacterCount))
    }
    return body
  }

  /// Splits comma- or newline-separated glossary entries.
  public static func parseTerms(_ raw: String) -> [String] {
    raw.components(separatedBy: CharacterSet(charactersIn: ",\n"))
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }
}
