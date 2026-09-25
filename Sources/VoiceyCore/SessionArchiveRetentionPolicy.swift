import Foundation

/// Pure retention rules for the local dictation session archive index.
public enum SessionArchiveRetentionPolicy {
  /// Returns record IDs to drop (oldest first) when `records.count` exceeds `maxEntries`.
  public static func recordIDsToEvict(
    records: [UtteranceArchiveRecord],
    maxEntries: Int
  ) -> [UUID] {
    guard maxEntries > 0, records.count > maxEntries else { return [] }
    let sorted = records.sorted { $0.createdAt < $1.createdAt }
    let overflow = sorted.count - maxEntries
    return sorted.prefix(overflow).map(\.id)
  }
}
