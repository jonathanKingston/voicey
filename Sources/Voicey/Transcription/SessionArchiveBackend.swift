import Foundation
import VoiceyCore

/// Routes dictation history I/O to `voicey-capture` (preferred) or `voicey-archive` (fallback).
enum SessionArchiveBackend {
  static func appendUtterance(
    archiveRoot: URL,
    audio: [String: Any],
    metadata: [String: Any],
    snapshot: UtteranceArchiveScreenSnapshot?,
    maxEntries: Int = SessionArchiveStore.defaultMaxEntries
  ) async throws {
    if VoiceyRuntimeConfiguration.useRustCaptureHotPath,
      VoiceyRuntimeConfiguration.captureWorkerPath != nil {
      try await VoiceyCaptureWorkerSession.shared.archiveUtterance(
        archiveRoot: archiveRoot,
        audio: audio,
        metadata: metadata,
        snapshot: snapshot,
        maxEntries: maxEntries
      )
      return
    }
    if VoiceyRuntimeConfiguration.archiveWorkerPath != nil {
      try await VoiceyArchiveWorkerSession.shared.appendUtterance(
        archiveRoot: archiveRoot,
        audio: audio,
        metadata: metadata,
        snapshot: snapshot,
        maxEntries: maxEntries
      )
      return
    }
    throw VoiceyArchiveWorkerError.missingBinary
  }

  static func deleteAll(archiveRoot: URL) async throws {
    if VoiceyRuntimeConfiguration.useRustCaptureHotPath,
      VoiceyRuntimeConfiguration.captureWorkerPath != nil {
      try await VoiceyCaptureWorkerSession.shared.deleteArchive(archiveRoot: archiveRoot)
      return
    }
    if VoiceyRuntimeConfiguration.archiveWorkerPath != nil {
      try await VoiceyArchiveWorkerSession.shared.deleteAll(archiveRoot: archiveRoot)
      return
    }
    throw VoiceyArchiveWorkerError.missingBinary
  }

  static var isAvailable: Bool {
    VoiceyRuntimeConfiguration.captureWorkerPath != nil
      || VoiceyRuntimeConfiguration.archiveWorkerPath != nil
  }
}
