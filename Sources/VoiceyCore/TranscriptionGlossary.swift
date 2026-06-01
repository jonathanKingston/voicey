import Foundation

/// Builds decoder context strings for on-device ASR vocabulary biasing.
public enum TranscriptionGlossary {
  /// Upper bound on glossary context length passed to the model.
  public static let maxContextCharacterCount = 2000

  /// Always included in steering glossaries when biasing is enabled.
  public static let builtInTerms: [String] = ["Voicey"]

  /// Prefix for Qwen3-ASR decoder context (system-slot biasing).
  public static let decoderContextPrefix = "Vocabulary: "

  /// Returns decoder context for the combined term list, or nil when empty.
  public static func decodingContext(terms: [String]) -> String? {
    TranscriptionDecoderContext.make(glossaryTerms: terms)
  }

  /// Returns decoder context when only a manual glossary is enabled.
  public static func decodingContext(enabled: Bool, rawGlossary: String) -> String? {
    guard enabled else { return nil }
    return decodingContext(terms: parseTerms(rawGlossary))
  }

  /// Normalizes user glossary text into a Qwen decoder context prefix.
  public static func format(_ raw: String) -> String {
    formatTerms(parseTerms(raw))
  }

  /// Formats an ordered term list into decoder context.
  public static func formatTerms(_ terms: [String]) -> String {
    guard !terms.isEmpty else { return "" }

    let joined = terms.joined(separator: ", ")
    let body = "\(decoderContextPrefix)\(joined)"
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
