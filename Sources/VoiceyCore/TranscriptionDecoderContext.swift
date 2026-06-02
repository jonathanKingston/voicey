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
}
