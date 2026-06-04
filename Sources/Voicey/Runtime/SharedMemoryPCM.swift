import Darwin
import Foundation
import os

/// Shared PCM files under the system temp directory (`voicey_pcm_*.pcm`).
///
/// Spec (protocol v1): matches the Rust `voicey-pcm` crate — little-endian f32 mono samples;
/// name is `voicey_pcm_{uuid}` with UUID v4 hex (no dashes); file is `{name}.pcm` in temp dir;
/// owner-only permissions (`0600` on Unix).
enum SharedMemoryPCM {
  private static let ownerOnlyPermissions: NSNumber = 0o600
  private static let fileNameSuffix = ".pcm"
  private static let uuidHexLength = 32

  static func write(samples: [Float]) throws -> String {
    let name = "voicey_pcm_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
    let url = fileURL(for: name)
    var data = Data(capacity: samples.count * MemoryLayout<Float>.size)
    for sample in samples {
      var littleEndian = sample.bitPattern.littleEndian
      withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
    try data.write(to: url, options: .atomic)
    try applyOwnerOnlyPermissions(at: url)
    return name
  }

  static func read(name: String, sampleCount: Int, sampleOffset: Int = 0) throws -> [Float] {
    let url = fileURL(for: name)
    let data = try Data(contentsOf: url)
    let sampleSize = MemoryLayout<Float>.size
    let byteOffset = sampleOffset * sampleSize
    let expected = sampleCount * sampleSize
    guard data.count >= byteOffset + expected else {
      throw SharedMemoryPCMError.bufferTooSmall
    }
    return data.withUnsafeBytes { rawBuffer in
      let bound = rawBuffer.bindMemory(to: Float.self)
      return Array(bound[sampleOffset..<(sampleOffset + sampleCount)])
    }
  }

  static func remove(name: String) {
    let url = fileURL(for: name)
    do {
      try FileManager.default.removeItem(at: url)
    } catch {
      if isMissingFileError(error) { return }
      AppLogger.runtime.warning(
        "Failed to remove shared PCM file \(name, privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
    }
  }

  /// Best-effort removal of stale `voicey_pcm_*.pcm` files in the temp directory.
  static func cleanupStaleFiles() {
    let tempDirectory = FileManager.default.temporaryDirectory
    guard
      let entries = try? FileManager.default.contentsOfDirectory(
        at: tempDirectory,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
      )
    else {
      AppLogger.runtime.warning("Failed to list temp directory for shared PCM cleanup")
      return
    }

    let currentOwnerID = getuid()
    var removedCount = 0
    for url in entries where isVoiceyPCMFile(url: url) {
      if !isOwnedByCurrentUser(url: url, currentOwnerID: currentOwnerID) {
        continue
      }
      do {
        try FileManager.default.removeItem(at: url)
        removedCount += 1
      } catch {
        if isMissingFileError(error) { continue }
        AppLogger.runtime.warning(
          "Failed to remove stale shared PCM file \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
        )
      }
    }
    if removedCount > 0 {
      AppLogger.runtime.info(
        "Removed \(removedCount, privacy: .public) stale shared PCM file(s)")
    }
  }

  static func fileURL(for name: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("\(name).pcm")
  }

  private static func applyOwnerOnlyPermissions(at url: URL) throws {
    try FileManager.default.setAttributes(
      [.posixPermissions: ownerOnlyPermissions],
      ofItemAtPath: url.path
    )
  }

  private static func isMissingFileError(_ error: Error) -> Bool {
    let nsError = error as NSError
    return nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileNoSuchFileError
  }

  private static func isVoiceyPCMFile(url: URL) -> Bool {
    let fileName = url.lastPathComponent
    guard fileName.hasPrefix("voicey_pcm_"), fileName.hasSuffix(fileNameSuffix) else {
      return false
    }
    let idPart = fileName.dropFirst("voicey_pcm_".count).dropLast(fileNameSuffix.count)
    return idPart.count == uuidHexLength && idPart.allSatisfy(\.isHexDigit)
  }

  private static func isOwnedByCurrentUser(url: URL, currentOwnerID: uid_t) -> Bool {
    // `URLResourceKey` exposes no file-owner key on Darwin; read the POSIX owner uid
    // via `FileManager` attributes instead. When ownership can't be read, default to
    // treating the file as ours so a readable stale file is still cleaned up.
    guard
      let ownerID = try? FileManager.default.attributesOfItem(atPath: url.path)[.ownerAccountID]
        as? NSNumber
    else {
      return true
    }
    return ownerID.uint32Value == currentOwnerID
  }
}

enum SharedMemoryPCMError: LocalizedError {
  case bufferTooSmall

  var errorDescription: String? {
    switch self {
    case .bufferTooSmall:
      return "Shared PCM buffer is smaller than expected"
    }
  }
}
