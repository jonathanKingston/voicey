import Foundation

/// Combines glossary terms into a Qwen decoder context string.
public enum TranscriptionDecoderContext {
  public static func make(
    glossaryTerms: [String],
    includeBuiltInGlossary: Bool = true
  ) -> String? {
    let mergedGlossary =
      (includeBuiltInGlossary ? TranscriptionGlossary.builtInTerms : []) + glossaryTerms
    let uniqueGlossary = ScreenTermSelector.dedupePreservingOrder(
      mergedGlossary,
      maxCount: ScreenTermSelector.defaultMaxTerms
    )
    guard !uniqueGlossary.isEmpty else { return nil }
    return TranscriptionGlossary.formatTerms(uniqueGlossary)
  }

  private static let spellingFragmentSeparator = " Spelling:"

  /// Steering segments that may be echoed without the full combined `decoder_context` string.
  public static func steeringFragmentsToStrip(from decoderContext: String) -> [String] {
    let normalized = decoderContext.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return [] }

    // Legacy combined glossary + spelling contexts (before spelling left decoder steering).
    if let range = normalized.range(of: spellingFragmentSeparator) {
      var fragments: [String] = []
      let glossaryPart = String(normalized[..<range.lowerBound])
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if !glossaryPart.isEmpty {
        fragments.append(glossaryPart)
      }
      let spellingBody = String(normalized[range.upperBound...])
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if !spellingBody.isEmpty {
        fragments.append("Spelling: \(spellingBody)")
      }
      return fragments
    }

    // Single-channel context (glossary only, post-split): strip it as one fragment.
    return [normalized]
  }
}
