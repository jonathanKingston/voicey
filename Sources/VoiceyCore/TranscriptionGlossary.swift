import Foundation

/// Builds decoder context strings for on-device ASR vocabulary biasing.
public enum TranscriptionGlossary {
  /// Upper bound on glossary context length passed to the model.
  public static let maxContextCharacterCount = 2000

  /// Always included in steering glossaries when biasing is enabled.
  public static let builtInTerms: [String] = ["Voicey"]

  /// Returns decoder context for the combined term list, or nil when empty.
  public static func decodingContext(terms: [String]) -> String? {
    let merged = builtInTerms + terms
    let unique = ScreenTermSelector.dedupePreservingOrder(
      merged,
      maxCount: ScreenTermSelector.defaultMaxTerms
    )
    guard !unique.isEmpty else { return nil }
    return formatTerms(unique)
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
    let body = "Glossary: \(joined)"
    guard body.count <= maxContextCharacterCount else {
      return String(body.prefix(maxContextCharacterCount))
    }
    return body
  }

  /// Removes decoder steering text when the model echoes it instead of transcribing speech.
  public static func strippingEchoedDecoderContext(_ text: String, decoderContext: String?) -> String {
    guard let decoderContext else { return text }
    let normalizedContext = decoderContext.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedContext.isEmpty else { return text }

    var remainder = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !remainder.isEmpty else { return remainder }

    if remainder == normalizedContext {
      return ""
    }
    if remainder.hasPrefix(normalizedContext) {
      remainder = String(remainder.dropFirst(normalizedContext.count))
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if remainder.hasPrefix(",") || remainder.hasPrefix(":") {
        remainder = remainder.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
      }
    }
    return remainder
  }

  /// Splits comma- or newline-separated glossary entries.
  public static func parseTerms(_ raw: String) -> [String] {
    raw.components(separatedBy: CharacterSet(charactersIn: ",\n"))
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }
}
