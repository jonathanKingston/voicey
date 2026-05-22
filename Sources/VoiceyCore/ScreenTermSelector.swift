import Foundation

/// Selects vocabulary terms from accessibility snapshots using BM25 and deduplication.
public enum ScreenTermSelector {
  public static let defaultMaxTerms = 60

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
    let rankedTerms = BM25.rankTerms(query: query, documents: chunks)

    var selected: [String] = []
    selected.append(contentsOf: mustKeep)

    let mustKeepKeys = Set(mustKeep.map { normalizedKey($0) })
    for entry in rankedTerms {
      let key = normalizedKey(entry.term)
      guard !mustKeepKeys.contains(key) else { continue }
      selected.append(entry.term)
      if selected.count >= maxTerms { break }
    }

    if selected.count < maxTerms, !query.isEmpty {
      let queryTokens = ScreenTermFilter.tokenize(query)
      for token in queryTokens {
        let key = normalizedKey(token)
        guard !mustKeepKeys.contains(key) else { continue }
        if !selected.contains(where: { normalizedKey($0) == key }) {
          selected.append(token)
        }
        if selected.count >= maxTerms { break }
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
