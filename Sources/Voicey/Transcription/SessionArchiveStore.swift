import Foundation
import VoiceyCore
import os

/// Reads local dictation history index; writes go through `voicey-archive`.
final class SessionArchiveStore: @unchecked Sendable {
  static let shared = SessionArchiveStore()
  static let defaultMaxEntries = 500
  static let indexFileName = "index.jsonl"

  private let fileManager: FileManager
  private let archiveRoot: URL
  private let jsonDecoder: JSONDecoder

  init(
    fileManager: FileManager = .default,
    archiveRoot: URL? = nil
  ) {
    self.fileManager = fileManager
    self.archiveRoot = archiveRoot ?? Self.defaultArchiveRoot(fileManager: fileManager)
    jsonDecoder = JSONDecoder()
    jsonDecoder.dateDecodingStrategy = .iso8601
    excludeFromBackupIfNeeded()
  }

  static func defaultArchiveRoot(fileManager: FileManager) -> URL {
    let appSupport =
      fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSTemporaryDirectory())
    return appSupport
      .appendingPathComponent("Voicey", isDirectory: true)
      .appendingPathComponent("SessionArchive", isDirectory: true)
  }

  func rootURL() -> URL { archiveRoot }

  func loadRecords() -> [UtteranceArchiveRecord] {
    let url = archiveRoot.appendingPathComponent(Self.indexFileName)
    guard let data = try? Data(contentsOf: url),
      let text = String(data: data, encoding: .utf8)
    else {
      return []
    }
    var records: [UtteranceArchiveRecord] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
      guard let lineData = line.data(using: .utf8),
        let record = try? jsonDecoder.decode(UtteranceArchiveRecord.self, from: lineData)
      else {
        continue
      }
      records.append(record)
    }
    return records
  }

  func deleteAll() async throws {
    try await SessionArchiveBackend.deleteAll(archiveRoot: archiveRoot)
    try fileManager.createDirectory(at: archiveRoot, withIntermediateDirectories: true)
    await MainActor.run {
      NotificationCenter.default.post(name: .voiceySessionArchiveDidChange, object: nil)
    }
  }

  func audioFileURL(for record: UtteranceArchiveRecord) -> URL {
    archiveRoot.appendingPathComponent(record.audioPath)
  }

  private func excludeFromBackupIfNeeded() {
    var resourceValues = URLResourceValues()
    resourceValues.isExcludedFromBackup = true
    var url = archiveRoot
    try? url.setResourceValues(resourceValues)
  }
}

extension Notification.Name {
  static let voiceySessionArchiveDidChange = Notification.Name("voiceySessionArchiveDidChange")
}
