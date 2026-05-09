import AppKit
import Darwin
import Dispatch
import Foundation

#if VOICEY_DIRECT_DISTRIBUTION || VOICEY_MEDIA_REMOTE_PROBE

  /// Subscribes to MediaRemote distributed notifications — often more reliable than polling
  /// `GetNowPlayingInfo` on recent macOS (e.g. empty dict for some browsers while IsPlaying still updates).
  enum MediaRemoteNowPlayingNotifications {
    private static let frameworkPath =
      "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"

    private typealias MRRegister = @convention(c) (DispatchQueue) -> Void

    private static let startLock = NSLock()
    private static var didStart = false
    private static var observers: [Any] = []

    private static let stateLock = NSLock()
    private static var lastIsPlaying: Bool?
    private static var lastIsPlayingChange: Date?

    /// If set within `ttl`, supplements `MediaRemotePlaybackProbe` when polling says “not playing”.
    static func recentIsPlayingHint(within ttl: TimeInterval = 8) -> Bool? {
      stateLock.lock()
      defer { stateLock.unlock() }
      guard let stamp = lastIsPlayingChange, let value = lastIsPlaying else { return nil }
      guard Date().timeIntervalSince(stamp) <= ttl else { return nil }
      return value
    }

    static func startIfNeeded() {
      startLock.lock()
      defer { startLock.unlock() }
      guard !didStart else { return }
      didStart = true

      guard let handle = dlopen(frameworkPath, RTLD_LAZY) else {
        AppLogger.general.warning("MediaRemote notifications: dlopen failed")
        return
      }

      // Bootstrap + read probes may already run from MediaRemotePlaybackProbe; avoid duplicate side effects here.

      if let sym = dlsym(handle, "MRMediaRemoteRegisterForNowPlayingNotifications") {
        let register = unsafeBitCast(sym, to: MRRegister.self)
        register(DispatchQueue.main)
      }

      // Do not dlsym CFString notification symbols: on some OS builds the export is not a CF object at the
      // symbol address, and CFGetTypeID on a bad pointer crashes at launch. Use documented-style names only.
      let isPlayingNames = Self.isPlayingDistributedNotificationNames()

      for name in isPlayingNames {
        let token = DistributedNotificationCenter.default().addObserver(
          forName: Notification.Name(name),
          object: nil,
          queue: .main
        ) { note in
          guard let parsed = Self.parseIsPlayingUserInfo(note.userInfo) else {
            if SettingsManager.shared.enableDetailedLogging {
              let keyList = note.userInfo?.keys.map { String(describing: $0) }.joined(separator: ", ") ?? ""
              AppLogger.general.info(
                "MediaRemote IsPlaying notification: could not parse userInfo keys=\(keyList, privacy: .public)"
              )
            }
            return
          }
          stateLock.lock()
          lastIsPlaying = parsed
          lastIsPlayingChange = Date()
          stateLock.unlock()
          if SettingsManager.shared.enableDetailedLogging {
            AppLogger.general.info("MediaRemote IsPlaying notification: parsed playing=\(parsed, privacy: .public)")
            debugPrint("MediaRemote notif IsPlaying=\(parsed)", category: "MEDIA")
          }
        }
        observers.append(token)
      }

      let didRegister = dlsym(handle, "MRMediaRemoteRegisterForNowPlayingNotifications") != nil
      AppLogger.general.info(
        "MediaRemote notifications: \(isPlayingNames.count) IsPlaying name(s), MR register=\(didRegister)"
      )
    }

    private static func isPlayingDistributedNotificationNames() -> [String] {
      [
        "com.apple.MRMediaRemoteNowPlayingApplicationIsPlayingDidChange",
        "com.apple.MRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification"
      ]
    }

    private static func parseIsPlayingUserInfo(_ userInfo: [AnyHashable: Any]?) -> Bool? {
      guard let dict = userInfo else { return nil }
      let stringKeys = [
        "kMRMediaRemoteNowPlayingApplicationIsPlayingUserInfoKey",
        "MRMediaRemoteNowPlayingApplicationIsPlaying",
        "Playing",
        "playing",
        "isPlaying"
      ]
      for key in stringKeys {
        if let boolVal = dict[key] as? Bool { return boolVal }
        if let numberVal = dict[key] as? NSNumber { return numberVal.boolValue }
        if let stringVal = dict[key] as? String {
          let lower = stringVal.lowercased()
          if lower == "true" || lower == "yes" || lower == "1" { return true }
          if lower == "false" || lower == "no" || lower == "0" { return false }
        }
      }
      for (anyKey, value) in dict {
        let keyDesc = String(describing: anyKey).lowercased()
        guard keyDesc.contains("playing") || keyDesc.contains("isplaying") else { continue }
        if let boolVal = value as? Bool { return boolVal }
        if let numberVal = value as? NSNumber { return numberVal.boolValue }
      }
      return nil
    }
  }

#else

  enum MediaRemoteNowPlayingNotifications {
    static func startIfNeeded() {}
    static func recentIsPlayingHint(within _: TimeInterval = 8) -> Bool? { nil }
  }

#endif
