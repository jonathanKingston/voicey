import Dispatch
import Foundation

#if VOICEY_DIRECT_DISTRIBUTION
  import Darwin

  /// Uses the private MediaRemote framework, opened with `dlopen` (no link-time dependency on the framework).
  /// Direct-distribution only; App Store builds must not ship this path.
  enum MediaRemotePlaybackProbe {
    private typealias MRGetNowPlaying = @convention(c) (
      DispatchQueue,
      @convention(block) (CFDictionary?) -> Void
    ) -> Void

    /// Prefer this over dictionary scraping when available: one boolean from MediaRemote.
    private typealias MRGetNowPlayingApplicationIsPlaying = @convention(c) (
      DispatchQueue,
      @convention(block) (Bool) -> Void
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
          fromApplicationCallback = isPlaying
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
        if keyString == "PlaybackRate" || keyString == "playbackRate",
          let number = value as? NSNumber, number.doubleValue > 0.001 {
          return true
        }
        // Some clients only publish playback state (1 ≈ playing).
        if keyString == "PlaybackState", let number = value as? NSNumber, number.intValue == 1 {
          return true
        }
      }
      return false
    }
  }

#else

  enum MediaRemotePlaybackProbe {
    /// MediaRemote is private API; App Store builds use scriptable-player fallback only.
    static func isMediaPlaying() -> Bool { false }
  }

#endif
