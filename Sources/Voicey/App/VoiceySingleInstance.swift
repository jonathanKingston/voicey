import AppKit
import Darwin
import Foundation

/// Why single-instance lock acquisition failed (infrastructure errors only).
enum SingleInstanceLockFailure: Equatable {
  case directoryCreationFailed
  case lockOpenFailed
  case flockFailed(errno: Int32)
}

/// Result of attempting to acquire the Voicey single-instance lock.
enum SingleInstanceLockResult: Equatable {
  case acquired
  case alreadyRunning
  case unavailable(SingleInstanceLockFailure)
  /// `VOICEY_ALLOW_MULTIPLE_INSTANCES=1` — no lock, hotkeys allowed for development.
  case multipleInstancesAllowed
}

/// Injectable file operations for unit tests (`open` / `flock` / `errno`).
struct SingleInstanceLockOperations {
  var createLockDirectory: () throws -> Void
  var openLockFile: () -> Int32
  var lockFilePath: () -> String
  var tryExclusiveLock: (Int32) -> Int32
  var currentErrno: () -> Int32
}

/// Ensures only one Voicey process owns the global shortcut (`KeyboardShortcuts`).
enum VoiceySingleInstance {
  /// Prevents multiple Voicey processes from each registering `KeyboardShortcuts` for the same chord
  /// (which would multiply recordings on one keypress). Set `VOICEY_ALLOW_MULTIPLE_INSTANCES=1` to disable.
  private static func lockFileURL() -> URL {
    let appSupport =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSTemporaryDirectory())
    let folder = appSupport.appendingPathComponent("Voicey", isDirectory: true)
    #if VOICEY_DIRECT_DISTRIBUTION
      return folder.appendingPathComponent("instance-VoiceyDirect.lock", isDirectory: false)
    #else
      return folder.appendingPathComponent("instance-Voicey.lock", isDirectory: false)
    #endif
  }

  static func productionLockOperations() -> SingleInstanceLockOperations {
    let lockURL = lockFileURL()
    return SingleInstanceLockOperations(
      createLockDirectory: {
        try FileManager.default.createDirectory(
          at: lockURL.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
      },
      openLockFile: {
        open(lockURL.path, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR)
      },
      lockFilePath: { lockURL.path },
      tryExclusiveLock: { fd in flock(fd, LOCK_EX | LOCK_NB) },
      currentErrno: { errno }
    )
  }

  /// Pure lock decision used by `acquireLock` and unit tests.
  static func evaluateLockOutcome(
    allowMultipleInstances: Bool,
    directoryCreationFailed: Bool,
    fileDescriptor: Int32,
    flockReturnValue: Int32,
    lockErrno: Int32
  ) -> SingleInstanceLockResult {
    if allowMultipleInstances {
      return .multipleInstancesAllowed
    }
    if directoryCreationFailed {
      return .unavailable(.directoryCreationFailed)
    }
    if fileDescriptor < 0 {
      return .unavailable(.lockOpenFailed)
    }
    if flockReturnValue != 0 {
      if lockErrno == EWOULDBLOCK || lockErrno == EAGAIN {
        return .alreadyRunning
      }
      return .unavailable(.flockFailed(errno: lockErrno))
    }
    return .acquired
  }

  /// Attempts to acquire the instance lock. Terminates the process when another instance holds it.
  static func acquireLock(
    operations: SingleInstanceLockOperations = productionLockOperations(),
    applyLockedFileDescriptor: (Int32) -> Void
  ) -> SingleInstanceLockResult {
    let allowMultiple =
      ProcessInfo.processInfo.environment["VOICEY_ALLOW_MULTIPLE_INSTANCES"] == "1"
    if allowMultiple {
      return .multipleInstancesAllowed
    }

    let lockPath = operations.lockFilePath()
    var directoryCreationFailed = false
    do {
      try operations.createLockDirectory()
    } catch {
      directoryCreationFailed = true
      AppLogger.general.error(
        "Voicey: could not create Application Support folder for instance lock: \(error)"
      )
    }

    let fd = operations.openLockFile()
    if fd < 0 {
      AppLogger.general.error("Voicey: could not open instance lock \(lockPath, privacy: .public)")
    }

    let flockResult = fd >= 0 ? operations.tryExclusiveLock(fd) : -1
    let lockErrno = flockResult != 0 ? operations.currentErrno() : 0
    if flockResult != 0, lockErrno != EWOULDBLOCK, lockErrno != EAGAIN {
      AppLogger.general.error("Voicey: flock instance lock failed errno=\(lockErrno)")
    }

    let outcome = evaluateLockOutcome(
      allowMultipleInstances: false,
      directoryCreationFailed: directoryCreationFailed,
      fileDescriptor: fd,
      flockReturnValue: flockResult,
      lockErrno: lockErrno
    )

    switch outcome {
    case .acquired:
      applyLockedFileDescriptor(fd)
      return .acquired
    case .alreadyRunning:
      AppLogger.general.warning(
        "Voicey: another instance is already running (see Activity Monitor for Voicey). Only one copy can own the global shortcut. Exiting. Lock: \(lockPath, privacy: .public)"
      )
      NSApp.terminate(nil)
      return .alreadyRunning
    case .unavailable, .multipleInstancesAllowed:
      return outcome
    }
  }

  static func presentLockUnavailableAlert(failure: SingleInstanceLockFailure, lockPath: String) {
    let detail: String
    switch failure {
    case .directoryCreationFailed:
      detail = "Voicey could not create its Application Support folder for the instance lock."
    case .lockOpenFailed:
      detail = "Voicey could not open the instance lock file."
    case .flockFailed(let lockErrno):
      detail = "Voicey could not lock the instance file (errno \(lockErrno))."
    }

    let alert = NSAlert()
    alert.messageText = "Voicey could not start safely"
    alert.informativeText = """
      \(detail)

      Lock file: \(lockPath)

      Fix disk permissions or free space, then relaunch Voicey. To run multiple copies for development only, set VOICEY_ALLOW_MULTIPLE_INSTANCES=1.
      """
    alert.alertStyle = .critical
    alert.addButton(withTitle: "Quit")
    alert.runModal()
  }
}
