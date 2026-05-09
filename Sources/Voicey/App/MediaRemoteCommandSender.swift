import Darwin
import Dispatch
import Foundation

#if VOICEY_DIRECT_DISTRIBUTION || VOICEY_MEDIA_REMOTE_PROBE

  /// Sends media commands through MediaRemote (same daemon path as Control Center). Often succeeds when
  /// synthetic `CGEvent` / `NSEvent.otherEvent` play/pause posts are ignored on recent macOS.
  enum MediaRemoteCommandSender {
    private static let frameworkPath =
      "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"

    /// Raw command values vary by OS; these are the commonly cited macOS mappings.
    private enum MRCommand: UInt32 {
      case play = 0
      case pause = 1
      case togglePlayPause = 2
    }

    /// `MRMediaRemoteSendCommand(command, userInfo, queue, completion)`
    private typealias MRSendCommand = @convention(c) (
      UInt32,
      NSDictionary?,
      DispatchQueue,
      @escaping @convention(block) (Bool, NSError?) -> Void
    ) -> Void

    private static let sendCommand: MRSendCommand? = {
      guard let handle = dlopen(frameworkPath, RTLD_LAZY) else { return nil }
      if let sym = dlsym(handle, "MRMediaRemoteBootstrap") {
        let bootstrap = unsafeBitCast(sym, to: (@convention(c) () -> Void).self)
        bootstrap()
      }
      guard let sym = dlsym(handle, "MRMediaRemoteSendCommand") else { return nil }
      return unsafeBitCast(sym, to: MRSendCommand.self)
    }()

    private static let callbackQueue = DispatchQueue(label: "work.voicey.mediaremote-send", qos: .userInitiated)

    private final class SendWaitGate {
      let semaphore = DispatchSemaphore(value: 0)
      private let lock = NSLock()
      private(set) var timedOut = false
      private(set) var completionFired = false
      private(set) var reportedSuccess = false

      func handleCompletion(success: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard !timedOut else { return }
        guard !completionFired else { return }
        completionFired = true
        reportedSuccess = success
        semaphore.signal()
      }

      func markTimedOut() {
        lock.lock()
        defer { lock.unlock() }
        timedOut = true
      }
    }

    /// Returns whether the completion ran with `true` before `timeout` (does **not** mean hardware paused).
    /// Late completions after a timeout are ignored so they cannot `signal` a reused semaphore pattern or
    /// stack with a follow-up `SendCommand` / HID toggle.
    private static func sendAndWait(command: MRCommand, timeout: TimeInterval) -> Bool {
      guard let sendCommand else { return false }
      let gate = SendWaitGate()
      sendCommand(command.rawValue, nil, callbackQueue) { success, _ in
        gate.handleCompletion(success: success)
      }
      let wait = gate.semaphore.wait(timeout: .now() + timeout)
      if wait == .timedOut {
        gate.markTimedOut()
        return false
      }
      guard gate.completionFired else { return false }
      return gate.reportedSuccess
    }

    static func sendPlayAndWait(timeout: TimeInterval = 0.35) -> Bool {
      sendAndWait(command: .play, timeout: timeout)
    }

    static func sendPauseAndWait(timeout: TimeInterval = 0.35) -> Bool {
      sendAndWait(command: .pause, timeout: timeout)
    }

    static func sendTogglePlayPauseAndWait(timeout: TimeInterval = 0.35) -> Bool {
      sendAndWait(command: .togglePlayPause, timeout: timeout)
    }
  }

#else

  enum MediaRemoteCommandSender {
    static func sendPlayAndWait(timeout _: TimeInterval = 0.35) -> Bool { false }
    static func sendPauseAndWait(timeout _: TimeInterval = 0.35) -> Bool { false }
    static func sendTogglePlayPauseAndWait(timeout _: TimeInterval = 0.35) -> Bool { false }
  }

#endif
