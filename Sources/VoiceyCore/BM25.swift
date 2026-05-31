import Foundation

/// Okapi BM25 ranking for lightweight on-device term selection.
public enum BM25 {
  public static func rankTerms(
    query: String,
    documents: [String],
    anchorVocabulary: [String] = [],
    k1: Float = 1.2,
    lengthNormalization: Float = 0.75
  ) -> [(term: String, score: Float)] {
    let anchors = anchorVocabulary
    let docTokens = documents.map { ScreenTermHealing.enrichedTokens(in: $0, anchors: anchors) }
    guard !docTokens.isEmpty else { return [] }

    let queryTokens = ScreenTermHealing.enrichedTokens(in: query, anchors: anchors)
    guard !queryTokens.isEmpty else { return [] }

    let avgDocLength = Float(docTokens.map(\.count).reduce(0, +)) / Float(docTokens.count)
    let documentFrequency = termDocumentFrequency(docTokens)
    let totalDocuments = docTokens.count

    var termScores: [String: Float] = [:]
    let candidateTerms = Set(docTokens.flatMap { $0 })

    for term in candidateTerms {
      let idf = inverseDocumentFrequency(
        documentFrequency: documentFrequency[term.lowercased(), default: 0],
        totalDocuments: totalDocuments
      )
      var score: Float = 0
      for tokens in docTokens {
        let termFrequency = Float(
          tokens.filter { $0.caseInsensitiveCompare(term) == .orderedSame }.count)
        guard termFrequency > 0 else { continue }
        let docLength = Float(tokens.count)
        let numerator = termFrequency * (k1 + 1)
        let denominator =
          termFrequency + k1
          * (1 - lengthNormalization + lengthNormalization * (docLength / max(avgDocLength, 1)))
        score += idf * (numerator / denominator)
      }
      if score > 0 {
        termScores[term] = score
      }
    }

    return
      termScores
      .map { (term: $0.key, score: $0.value) }
      .sorted {
        if $0.score != $1.score { return $0.score > $1.score }
        return $0.term.localizedCaseInsensitiveCompare($1.term) == .orderedAscending
      }
  }

  private static func termDocumentFrequency(_ docTokens: [[String]]) -> [String: Int] {
    var frequency: [String: Int] = [:]
    for tokens in docTokens {
      let unique = Set(tokens.map { $0.lowercased() })
      for term in unique {
        frequency[term, default: 0] += 1
      }
    }
    return frequency
  }

  private static func inverseDocumentFrequency(documentFrequency: Int, totalDocuments: Int) -> Float {
    let docFreq = Float(documentFrequency)
    let total = Float(totalDocuments)
    return log((total - docFreq + 0.5) / (docFreq + 0.5) + 1)
  }
}
