import Foundation

/// Text gathered from the accessibility tree for vocabulary steering (platform-agnostic).
public struct ScreenContextSnapshot: Sendable, Equatable {
  /// Focused value, selection, and similar high-signal text used as the BM25 query.
  public let queryText: String
  /// Shallow AX walk chunks scored against the query.
  public let corpusChunks: [String]

  public init(queryText: String, corpusChunks: [String]) {
    self.queryText = queryText
    self.corpusChunks = corpusChunks
  }

  public static let empty = ScreenContextSnapshot(queryText: "", corpusChunks: [])
}
