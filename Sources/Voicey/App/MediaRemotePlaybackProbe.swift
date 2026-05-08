import Dispatch
import Foundation

#if VOICEY_DIRECT_DISTRIBUTION
  import CoreFoundation
  import Darwin

  /// Uses the private MediaRemote framework, opened with `dlopen` (no link-time dependency on the framework).
  /// Direct-distribution only; App Store builds must not ship this path.
  ///
  /// Control Center’s “Now Playing” tile reads the same underlying session this code queries: apps publish
  /// metadata and playback state to MediaRemote; `GetNowPlayingInfo` / `GetNowPlayingApplicationIsPlaying`
  /// mirror that. If the tile shows a Play (not Pause) control, the session is paused—sending a global
  /// play/pause toggle would *start* audio, so Voicey intentionally skips arming resume in that case.
  enum MediaRemotePlaybackProbe {
    private typealias MRGetNowPlaying = @convention(c) (
      DispatchQueue,
      @convention(block) (CFDictionary?) -> Void
    ) -> Void

    /// Prefer this over dictionary scraping when available: one boolean from MediaRemote.
    /// Uses `ObjCBool` because the C API exposes `BOOL` in the block signature.
    private typealias MRGetNowPlayingApplicationIsPlaying = @convention(c) (
      DispatchQueue,
      @convention(block) (ObjCBool) -> Void
    ) -> Void

    private static let handles: ProbeHandles? = {
      guard
        let handle = dlopen(
          "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",
          RTLD_NOW
        )
      else {
        return nil
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

      guard getNowPlaying != nil || getApplicationIsPlaying != nil else {
        return nil
      }
      return ProbeHandles(
        dlHandle: handle,
        getNowPlaying: getNowPlaying,
        getApplicationIsPlaying: getApplicationIsPlaying
      )
    }()

    private struct ProbeHandles {
      let dlHandle: UnsafeMutableRawPointer
      let getNowPlaying: MRGetNowPlaying?
      let getApplicationIsPlaying: MRGetNowPlayingApplicationIsPlaying?
    }

    /// Whether the system Now Playing session reports active playback.
    /// Prefers `MRMediaRemoteGetNowPlayingApplicationIsPlaying` when linked; falls back to Now Playing dictionary keys.
    static func isMediaPlaying() -> Bool {
      guard let handles else { return false }
      return DispatchQueue.global(qos: .userInitiated).sync {
        Self.queryIsPlaying(handles: handles)
      }
    }

    private static func queryIsPlaying(handles: ProbeHandles) -> Bool {
      let callbackQueue = DispatchQueue(label: "work.voicey.mediaremote-callback", qos: .userInitiated)

      var fromApplicationCallback: Bool?
      if let getApplicationIsPlaying = handles.getApplicationIsPlaying {
        let semaphore = DispatchSemaphore(value: 0)
        getApplicationIsPlaying(callbackQueue) { isPlaying in
          defer { semaphore.signal() }
          fromApplicationCallback = isPlaying.boolValue
        }
        _ = semaphore.wait(timeout: .now() + 0.15)
      }

      if fromApplicationCallback == true {
        return true
      }

      var fromDictionary = false
      if let getNowPlaying = handles.getNowPlaying {
        let semaphore = DispatchSemaphore(value: 0)
        getNowPlaying(callbackQueue) { raw in
          defer { semaphore.signal() }
          guard let raw else { return }
          fromDictionary = Self.isPlaying(nowPlayingInfo: raw)
        }
        _ = semaphore.wait(timeout: .now() + 0.15)
      }

      if let applicationAnswer = fromApplicationCallback {
        return applicationAnswer || fromDictionary
      }
      return fromDictionary
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
    /// MediaRemote is private API; App Store builds use scriptable-player fallback only.
    static func isMediaPlaying() -> Bool { false }
  }

#endif
