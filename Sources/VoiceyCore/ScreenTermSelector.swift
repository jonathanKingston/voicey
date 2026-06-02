import Foundation

/// Selects vocabulary terms from accessibility snapshots using BM25 and deduplication.
public enum ScreenTermSelector {
  /// Maximum BM25 / query screen-derived terms (beyond manual glossary + built-ins).
  public static let defaultMaxScreenTerms = 16

  /// Hard cap on terms passed into decoder context (manual glossary + screen).
  public static let defaultMaxTerms = 48

  public static func select(
    snapshot: ScreenContextSnapshot?,
    manualGlossary: String,
    manualGlossaryEnabled: Bool,
    maxTerms: Int = defaultMaxTerms
  ) -> [String] {
    var mustKeep: [String] = []
    if manualGlossaryEnabled {
      mustKeep.append(contentsOf: TranscriptionGlossary.parseTerms(manualGlossary))
    }

    guard let snapshot else {
      return dedupePreservingOrder(mustKeep, maxCount: maxTerms)
    }

    let queryParts = [snapshot.queryText, manualGlossaryEnabled ? manualGlossary : ""]
      .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    let query = queryParts.joined(separator: " ")

    let chunks = snapshot.corpusChunks.filter { !ScreenTermFilter.isNoiseChunk($0) }
    let corpusAnchors =
      chunks
      .flatMap { ScreenTermFilter.tokenize($0) }
      .filter { $0.count >= 5 }
    let anchors = ScreenTermSelector.dedupePreservingOrder(
      TranscriptionGlossary.builtInTerms + mustKeep + corpusAnchors,
      maxCount: 200
    )
    let rankedTerms = BM25.rankTerms(query: query, documents: chunks, anchorVocabulary: anchors)

    var selected: [String] = []
    selected.append(contentsOf: mustKeep)

    let mustKeepKeys = Set(mustKeep.map { normalizedKey($0) })
    let screenBudget = min(defaultMaxScreenTerms, max(0, maxTerms - selected.count))
    var screenAdded = 0

    for entry in rankedTerms {
      let term = ScreenTermHealing.canonicalTerm(entry.term, anchors: anchors)
      guard !ScreenTermFilter.isSteeringNoiseToken(term) else { continue }
      guard !ScreenTermHealing.isInteriorFragment(term, anchors: anchors) else { continue }
      let key = normalizedKey(entry.term)
      guard !mustKeepKeys.contains(key) else { continue }
      selected.append(term)
      screenAdded += 1
      if screenAdded >= screenBudget || selected.count >= maxTerms { break }
    }

    if screenAdded < screenBudget, selected.count < maxTerms, !query.isEmpty {
      let queryTokens = ScreenTermHealing.enrichedTokens(in: query, anchors: anchors)
      for token in queryTokens {
        guard !ScreenTermFilter.isSteeringNoiseToken(token) else { continue }
        guard !ScreenTermHealing.isInteriorFragment(token, anchors: anchors) else { continue }
        let key = normalizedKey(token)
        guard !mustKeepKeys.contains(key) else { continue }
        if !selected.contains(where: { normalizedKey($0) == key }) {
          selected.append(token)
          screenAdded += 1
        }
        if screenAdded >= screenBudget || selected.count >= maxTerms { break }
      }
    }

    return dedupePreservingOrder(selected, maxCount: maxTerms)
  }

  public static func dedupePreservingOrder(_ terms: [String], maxCount: Int) -> [String] {
    var seen: Set<String> = []
    var result: [String] = []
    for term in terms {
      let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { continue }
      let key = normalizedKey(trimmed)
      guard !seen.contains(key) else { continue }
      seen.insert(key)
      result.append(trimmed)
      if result.count >= maxCount { break }
    }
    return result
  }

  private static func normalizedKey(_ term: String) -> String {
    term.lowercased().filter { $0.isLetter || $0.isNumber }
  }
}
