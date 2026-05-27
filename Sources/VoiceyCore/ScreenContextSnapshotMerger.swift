import Foundation

/// Combines accessibility and supplemental (e.g. OCR) screen context snapshots.
public enum ScreenContextSnapshotMerger {
  public static func merging(
    _ base: ScreenContextSnapshot,
    supplemental: ScreenContextSnapshot
  ) -> ScreenContextSnapshot {
    let baseQuery = base.queryText.trimmingCharacters(in: .whitespacesAndNewlines)
    let supplementalQuery = supplemental.queryText.trimmingCharacters(in: .whitespacesAndNewlines)
    let queryText = baseQuery.isEmpty ? supplementalQuery : baseQuery

    var seen = Set<String>()
    var corpusChunks: [String] = []
    for chunk in base.corpusChunks + supplemental.corpusChunks {
      let key = chunk.lowercased()
      guard !key.isEmpty, !seen.contains(key) else { continue }
      seen.insert(key)
      corpusChunks.append(chunk)
    }

    return ScreenContextSnapshot(queryText: queryText, corpusChunks: corpusChunks)
  }
}
