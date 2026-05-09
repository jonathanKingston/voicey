import Dispatch
import Foundation

#if VOICEY_DIRECT_DISTRIBUTION || VOICEY_MEDIA_REMOTE_PROBE
  import CoreFoundation
  import Darwin

  /// Uses the private MediaRemote framework, opened with `dlopen` (no link-time dependency on the framework).
  /// Enabled for direct distribution (`VOICEY_DIRECT_DISTRIBUTION`) or when built with `VOICEY_MEDIA_REMOTE_PROBE`
  /// (e.g. `make build`, Xcode Debug). App Store release archives omit the probe flag.
  ///
  /// Control Center’s “Now Playing” tile reads the same underlying session this code queries: apps publish
  /// metadata and playback state to MediaRemote; `GetNowPlayingInfo` / `GetNowPlayingApplicationIsPlaying`
  /// mirror that. If the tile shows a Play (not Pause) control, the session is paused—sending a global
  /// play/pause toggle would *start* audio, so Voicey intentionally skips arming resume in that case.
  enum MediaRemotePlaybackProbe {
    /// MediaRemote invokes these blocks asynchronously on `queue`; the block parameters must use `@escaping`
    /// (only valid here, inside the `@convention(c)` parameter list) or Swift traps with “non-escaping closure has escaped”.
    private typealias MRGetNowPlaying = @convention(c) (
      DispatchQueue,
      @escaping @convention(block) (CFDictionary?) -> Void
    ) -> Void

    /// Prefer this over dictionary scraping when available: one boolean from MediaRemote.
    /// The block takes Obj-C `BOOL`, which Swift imports as `Bool` (not `ObjCBool`) for correct ABI.
    private typealias MRGetNowPlayingApplicationIsPlaying = @convention(c) (
      DispatchQueue,
      @escaping @convention(block) (Bool) -> Void
    ) -> Void

    /// Synchronous snapshot; some sessions (e.g. Firefox) populate this when async `GetNowPlayingInfo` is empty.
    private typealias MRCopyNowPlayingInfo = @convention(c) () -> Unmanaged<CFDictionary>?

    private typealias MRBootstrap = @convention(c) () -> Void

    private static let handles: ProbeHandles? = {
      guard
        let handle = dlopen(
          "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",
          RTLD_NOW
        )
      else {
        return nil
      }
      if let sym = dlsym(handle, "MRMediaRemoteBootstrap") {
        let bootstrap = unsafeBitCast(sym, to: MRBootstrap.self)
        bootstrap()
      }

      let getNowPlaying: MRGetNowPlaying?
      if let sym = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo") {
        getNowPlaying = unsafeBitCast(sym, to: MRGetNowPlaying.self)
      } else {
        getNowPlaying = nil
      }

      let getApplicationIsPlaying: MRGetNowPlayingApplicationIsPlaying?
      if let sym = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying") {
        getApplicationIsPlaying = unsafeBitCast(sym, to: MRGetNowPlayingApplicationIsPlaying.self)
      } else {
        getApplicationIsPlaying = nil
      }

      let copyNowPlayingInfo: MRCopyNowPlayingInfo?
      if let sym = dlsym(handle, "MRMediaRemoteCopyNowPlayingInfo") {
        copyNowPlayingInfo = unsafeBitCast(sym, to: MRCopyNowPlayingInfo.self)
      } else {
        copyNowPlayingInfo = nil
      }

      guard getNowPlaying != nil || getApplicationIsPlaying != nil || copyNowPlayingInfo != nil else {
        return nil
      }
      return ProbeHandles(
        dlHandle: handle,
        getNowPlaying: getNowPlaying,
        getApplicationIsPlaying: getApplicationIsPlaying,
        copyNowPlayingInfo: copyNowPlayingInfo
      )
    }()

    private struct ProbeHandles {
      let dlHandle: UnsafeMutableRawPointer
      let getNowPlaying: MRGetNowPlaying?
      let getApplicationIsPlaying: MRGetNowPlayingApplicationIsPlaying?
      let copyNowPlayingInfo: MRCopyNowPlayingInfo?
    }

    /// Whether the system Now Playing session reports active playback.
    /// When bundled, prefers the Perl + `MediaRemoteAdapter.framework` snapshot (system `perl` entitlement trampoline);
    /// otherwise uses in-process `dlopen` polling. Supplements with a short-TTL hint from distributed IsPlaying
    /// notifications when the primary path reports not playing.
    static func isMediaPlaying() -> Bool {
      if let perlPlaying = MediaRemotePerlAdapter.snapshotPlayingState() {
        if perlPlaying {
          if SettingsManager.shared.enableDetailedLogging {
            AppLogger.general.info("MediaRemote: using Perl adapter snapshot (playing)")
            debugPrint("MediaRemote: perl playing=true", category: "MEDIA")
          }
          return true
        }
        if MediaRemoteNowPlayingNotifications.recentIsPlayingHint(within: 8) == true {
          if SettingsManager.shared.enableDetailedLogging {
            AppLogger.general.info(
              "MediaRemote: Perl snapshot not playing; treating as playing from recent IsPlaying notification"
            )
            debugPrint("MediaRemote: perl false + notif hint true", category: "MEDIA")
          }
          return true
        }
        if SettingsManager.shared.enableDetailedLogging {
          AppLogger.general.info("MediaRemote: using Perl adapter snapshot (not playing)")
          debugPrint("MediaRemote: perl playing=false", category: "MEDIA")
        }
        return false
      }

      let polled: Bool
      if let handles {
        polled = DispatchQueue.global(qos: .userInitiated).sync {
          Self.logCapabilitiesOnce(handles: handles)
          return Self.queryIsPlaying(handles: handles)
        }
        if polled { return true }
      } else {
        AppLogger.general.warning("MediaRemote: dlopen/symbols unavailable; treating as not playing")
        debugPrint("MediaRemote: handles nil (dlopen or symbols missing)", category: "MEDIA")
      }

      if MediaRemoteNowPlayingNotifications.recentIsPlayingHint(within: 8) == true {
        if SettingsManager.shared.enableDetailedLogging {
          AppLogger.general.info("MediaRemote: treating as playing from recent IsPlaying distributed notification")
          debugPrint("MediaRemote: using IsPlaying notification hint", category: "MEDIA")
        }
        return true
      }
      return false
    }

    private static var didLogCapabilities = false

    private static func logCapabilitiesOnce(handles: ProbeHandles) {
      guard !didLogCapabilities else { return }
      didLogCapabilities = true
      let hasGet = handles.getNowPlaying != nil
      let hasIsPlaying = handles.getApplicationIsPlaying != nil
      let hasCopy = handles.copyNowPlayingInfo != nil
      AppLogger.general.info(
        "MediaRemote: capabilities — GetNowPlaying: \(hasGet), IsPlayingAPI: \(hasIsPlaying), CopyNowPlaying: \(hasCopy)"
      )
      debugPrint(
        "MediaRemote: GetNowPlaying=\(hasGet) IsPlayingAPI=\(hasIsPlaying) Copy=\(hasCopy)",
        category: "MEDIA"
      )
    }

    private struct CopyNowPlayingSnapshot {
      let playing: Bool
      let keyCount: Int
      let keySample: String
    }

    private static func evaluateCopyNowPlaying(handles: ProbeHandles, verbose: Bool) -> CopyNowPlayingSnapshot {
      guard let copy = handles.copyNowPlayingInfo else {
        return CopyNowPlayingSnapshot(playing: false, keyCount: 0, keySample: "")
      }
      guard let unmanaged = copy() else {
        if verbose {
          AppLogger.general.info("MediaRemote CopyNowPlayingInfo: copy() returned nil (no snapshot)")
          debugPrint("MediaRemote Copy: nil", category: "MEDIA")
        }
        return CopyNowPlayingSnapshot(playing: false, keyCount: 0, keySample: "")
      }
      let rawDict = unmanaged.takeRetainedValue()
      let dict = rawDict as NSDictionary
      let keyCount = dict.count
      let playing = Self.isPlaying(nowPlayingInfo: rawDict)
      var keySample = ""
      if verbose {
        let names = dict.allKeys.compactMap { key -> String? in
          if let str = key as? String { return str }
          if let str = key as? NSString { return str as String }
          return nil
        }.sorted()
        keySample = names.prefix(24).joined(separator: ", ")
        AppLogger.general.info(
          "MediaRemote CopyNowPlayingInfo: keyCount=\(keyCount), dictSaysPlaying=\(playing)"
        )
        AppLogger.general.info(
          "MediaRemote CopyNowPlayingInfo keysSample=\(keySample, privacy: .public)"
        )
        debugPrint(
          "MediaRemote Copy: keys=\(keyCount) playing=\(playing) sample=[\(keySample)]",
          category: "MEDIA"
        )
      }
      return CopyNowPlayingSnapshot(playing: playing, keyCount: keyCount, keySample: keySample)
    }

    private static func queryIsPlaying(handles: ProbeHandles) -> Bool {
      let verbose = SettingsManager.shared.enableDetailedLogging
      let callbackQueue = DispatchQueue(label: "work.voicey.mediaremote-callback", qos: .userInitiated)

      let copySnap = Self.evaluateCopyNowPlaying(handles: handles, verbose: verbose)
      let fromCopyDictionary = copySnap.playing
      let copyKeyCount = copySnap.keyCount

      if fromCopyDictionary {
        return true
      }

      var fromApplicationCallback: Bool?
      var isPlayingCallbackFired = false
      if let getApplicationIsPlaying = handles.getApplicationIsPlaying {
        let semaphore = DispatchSemaphore(value: 0)
        getApplicationIsPlaying(callbackQueue) { isPlaying in
          defer { semaphore.signal() }
          isPlayingCallbackFired = true
          fromApplicationCallback = isPlaying
        }
        let wait = semaphore.wait(timeout: .now() + 0.15)
        if verbose {
          AppLogger.general.info(
            "MediaRemote IsPlaying API: fired=\(isPlayingCallbackFired), value=\(String(describing: fromApplicationCallback)), timedOut=\(wait == .timedOut)"
          )
          debugPrint(
            "MediaRemote IsPlaying: fired=\(isPlayingCallbackFired) value=\(String(describing: fromApplicationCallback)) timedOut=\(wait == .timedOut)",
            category: "MEDIA"
          )
        }
      } else if verbose {
        AppLogger.general.info("MediaRemote: MRMediaRemoteGetNowPlayingApplicationIsPlaying symbol missing")
        debugPrint("MediaRemote: IsPlaying symbol missing", category: "MEDIA")
      }

      if fromApplicationCallback == true {
        return true
      }

      var fromDictionary = false
      var nowPlayingKeyCount = 0
      var nowPlayingKeySample = ""
      var nowPlayingCallbackFired = false
      if let getNowPlaying = handles.getNowPlaying {
        let semaphore = DispatchSemaphore(value: 0)
        getNowPlaying(callbackQueue) { raw in
          defer { semaphore.signal() }
          nowPlayingCallbackFired = true
          guard let raw else { return }
          let dict = raw as NSDictionary
          nowPlayingKeyCount = dict.count
          if verbose {
            let names = dict.allKeys.compactMap { key -> String? in
              if let str = key as? String { return str }
              if let str = key as? NSString { return str as String }
              return nil
            }.sorted()
            nowPlayingKeySample = names.prefix(24).joined(separator: ", ")
          }
          fromDictionary = Self.isPlaying(nowPlayingInfo: raw)
        }
        let wait = semaphore.wait(timeout: .now() + 0.15)
        if verbose {
          let timedOut = wait == .timedOut
          AppLogger.general.info(
            "MediaRemote GetNowPlayingInfo: fired=\(nowPlayingCallbackFired), keyCount=\(nowPlayingKeyCount), dictSaysPlaying=\(fromDictionary), timedOut=\(timedOut)"
          )
          AppLogger.general.info(
            "MediaRemote GetNowPlayingInfo keysSample=\(nowPlayingKeySample, privacy: .public)"
          )
          debugPrint(
            "MediaRemote NowPlaying: fired=\(nowPlayingCallbackFired) keys=\(nowPlayingKeyCount) playing=\(fromDictionary) timedOut=\(timedOut) sample=[\(nowPlayingKeySample)]",
            category: "MEDIA"
          )
        }
      } else if verbose {
        AppLogger.general.info("MediaRemote: MRMediaRemoteGetNowPlayingInfo symbol missing")
        debugPrint("MediaRemote: GetNowPlayingInfo symbol missing", category: "MEDIA")
      }

      let result: Bool
      if let applicationAnswer = fromApplicationCallback {
        result = applicationAnswer || fromDictionary
      } else {
        result = fromDictionary
      }

      if !verbose, !result {
        AppLogger.general.info(
          "MediaRemote: combined not playing (IsPlaying=\(String(describing: fromApplicationCallback)), dict=\(fromDictionary), copyDict=\(fromCopyDictionary), copyKeys=\(copyKeyCount))"
        )
        AppLogger.general.info(
          "MediaRemote: enable Voicey Settings → Advanced → detailed logging for MR callback diagnostics"
        )
      }

      return result
    }

    private static func isPlaying(nowPlayingInfo: CFDictionary) -> Bool {
      let dict = nowPlayingInfo as NSDictionary
      for (key, value) in dict {
        let keyString: String
        if let str = key as? String {
          keyString = str
        } else if let str = key as? NSString {
          keyString = str as String
        } else {
          continue
        }
        let keyLower = keyString.lowercased()

        if keyLower == "playbackrate" || keyLower.hasSuffix("playbackrate") || keyLower.contains("playbackrate"),
          let rate = numericDouble(value), rate > 0.001 {
          return true
        }

        // `MPNowPlayingPlaybackState.playing` raw value is 1; some publishers use the prefixed key.
        if keyLower == "playbackstate" || keyLower.hasSuffix("playbackstate")
          || keyLower == "mpnowplayingplaybackstate" {
          if let state = numericInt(value), state == 1 {
            return true
          }
        }

        // Browsers / MR clients sometimes publish boolean-ish “playing” keys with varied names.
        if keyLower == "isplaying" || keyLower.hasSuffix("isplaying") {
          if let intVal = numericInt(value), intVal != 0 { return true }
          if let doubleVal = numericDouble(value), doubleVal > 0.001 { return true }
        }
      }
      return false
    }

    private static func numericDouble(_ value: Any?) -> Double? {
      guard let value else { return nil }
      if let number = value as? NSNumber { return number.doubleValue }
      if let double = value as? Double { return double }
      if let float = value as? Float { return Double(float) }
      if let int = value as? Int { return Double(int) }

      let cf = value as AnyObject
      let typeId = CFGetTypeID(cf)
      if typeId == CFNumberGetTypeID() {
        // swiftlint:disable:next force_cast
        let number = cf as! CFNumber
        var doubleValue = 0.0
        if CFNumberGetValue(number, .doubleType, &doubleValue) { return doubleValue }
        var intValue = 0
        if CFNumberGetValue(number, .intType, &intValue) { return Double(intValue) }
      }
      return nil
    }

    private static func numericInt(_ value: Any?) -> Int? {
      guard let value else { return nil }
      if let number = value as? NSNumber { return number.intValue }
      if let int = value as? Int { return int }

      let cf = value as AnyObject
      if CFGetTypeID(cf) == CFNumberGetTypeID() {
        // swiftlint:disable:next force_cast
        let number = cf as! CFNumber
        var intValue = 0
        if CFNumberGetValue(number, .intType, &intValue) { return intValue }
      }
      return nil
    }
  }

#else

  enum MediaRemotePlaybackProbe {
    /// No MediaRemote path: build without `VOICEY_MEDIA_REMOTE_PROBE` / `VOICEY_DIRECT_DISTRIBUTION` (App Store release).
    static func isMediaPlaying() -> Bool { false }
  }

#endif
