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

    private static let handles: ProbeHandles? = {
      guard
        let handle = dlopen(
          "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",
          RTLD_NOW
        )
      else {
        return nil
      }
      guard let symbol = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo") else {
        return ProbeHandles(dlHandle: handle, getNowPlaying: nil)
      }
      let fn = unsafeBitCast(symbol, to: MRGetNowPlaying.self)
      return ProbeHandles(dlHandle: handle, getNowPlaying: fn)
    }()

    private struct ProbeHandles {
      let dlHandle: UnsafeMutableRawPointer
      let getNowPlaying: MRGetNowPlaying?
    }

    /// Whether the system Now Playing session reports active playback (`playbackRate` > 0).
    /// Runs the MediaRemote callback wait on a background queue so the caller is not blocked
    /// for the full timeout when the callback never fires.
    static func isMediaPlaying() -> Bool {
      guard let getNowPlaying = handles?.getNowPlaying else { return false }
      return DispatchQueue.global(qos: .userInitiated).sync {
        var playing = false
        let semaphore = DispatchSemaphore(value: 0)
        let callbackQueue = DispatchQueue(label: "work.voicey.mediaremote-callback", qos: .userInitiated)
        getNowPlaying(callbackQueue) { raw in
          defer { semaphore.signal() }
          guard let raw else { return }
          playing = Self.isPlaying(nowPlayingInfo: raw)
        }
        _ = semaphore.wait(timeout: .now() + 0.15)
        return playing
      }
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
