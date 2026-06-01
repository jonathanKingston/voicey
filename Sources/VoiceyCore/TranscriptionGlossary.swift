import Foundation

/// Builds decoder context strings for on-device ASR vocabulary biasing.
public enum TranscriptionGlossary {
  /// Upper bound on glossary context length passed to the model.
  public static let maxContextCharacterCount = 2000

  /// Always included in steering glossaries when biasing is enabled.
  public static let builtInTerms: [String] = ["Voicey"]

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

    var prefixes = [normalizedContext]
    prefixes.append(contentsOf: TranscriptionDecoderContext.steeringFragmentsToStrip(from: normalizedContext))
    var seen: Set<String> = []
    let uniquePrefixes =
      prefixes
      .filter { prefix in
        guard !prefix.isEmpty, !seen.contains(prefix) else { return false }
        seen.insert(prefix)
        return true
      }
      .sorted { $0.count > $1.count }

    var changed = true
    while changed {
      changed = false
      for prefix in uniquePrefixes {
        if remainder == prefix {
          return ""
        }
        if remainder.hasPrefix(prefix) {
          remainder = String(remainder.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
          if remainder.hasPrefix(",") || remainder.hasPrefix(":") {
            remainder = remainder.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
          }
          changed = true
          break
        }
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
