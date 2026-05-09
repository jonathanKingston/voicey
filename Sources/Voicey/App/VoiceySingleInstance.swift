import AppKit
import Darwin
import Foundation

/// Ensures only one Voicey process owns the global shortcut (`KeyboardShortcuts`).
enum VoiceySingleInstance {
  /// Prevents multiple Voicey processes from each registering `KeyboardShortcuts` for the same chord
  /// (which would multiply recordings on one keypress). Set `VOICEY_ALLOW_MULTIPLE_INSTANCES=1` to disable.
  private static func lockFileURL() -> URL {
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSTemporaryDirectory())
    let folder = appSupport.appendingPathComponent("Voicey", isDirectory: true)
    #if VOICEY_DIRECT_DISTRIBUTION
      return folder.appendingPathComponent("instance-VoiceyDirect.lock", isDirectory: false)
    #else
      return folder.appendingPathComponent("instance-Voicey.lock", isDirectory: false)
    #endif
  }

  /// - Returns: `false` when another instance holds the lock and this process is terminating.
  static func acquireLockOrQuit(applyLockedFileDescriptor: (Int32) -> Void) -> Bool {
    if ProcessInfo.processInfo.environment["VOICEY_ALLOW_MULTIPLE_INSTANCES"] == "1" {
      return true
    }

    let lockURL = lockFileURL()
    do {
      try FileManager.default.createDirectory(
        at: lockURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
    } catch {
      AppLogger.general.error("Voicey: could not create Application Support folder for instance lock: \(error)")
      return true
    }

    let path = lockURL.path
    let fd = open(path, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR)
    if fd < 0 {
      AppLogger.general.error("Voicey: could not open instance lock \(path, privacy: .public)")
      return true
    }

    if flock(fd, LOCK_EX | LOCK_NB) != 0 {
      let lockErr = errno
      if lockErr == EWOULDBLOCK || lockErr == EAGAIN {
        AppLogger.general.warning(
          "Voicey: another instance is already running (see Activity Monitor for Voicey). Only one copy can own the global shortcut. Exiting. Lock: \(path, privacy: .public)"
        )
        NSApp.terminate(nil)
        return false
      }
      AppLogger.general.error("Voicey: flock instance lock failed errno=\(lockErr)")
    }

    applyLockedFileDescriptor(fd)
    return true
  }
}
