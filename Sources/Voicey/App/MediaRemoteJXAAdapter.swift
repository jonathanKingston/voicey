import Foundation

#if VOICEY_DIRECT_DISTRIBUTION || VOICEY_MEDIA_REMOTE_PROBE

  /// Runs Apple **JavaScript for Automation** under `/usr/bin/osascript` to read Now Playing via
  /// `MediaRemote.framework` (same approach as [media-remote](https://github.com/nohackjustnoobb/media-remote)
  /// `NowPlayingJXA` / `assets/nowPlaying.jxa`, MIT License Copyright (c) 2025 nohackjustnoobb).
  ///
  /// Uses system `/usr/bin/osascript` (no extra bundled binaries) while still working around strict
  /// `mediaremoted` client checks on recent macOS (see that crate’s README “macOS 15.4+”).
  enum MediaRemoteJXAAdapter {
    private static let osascriptPath = "/usr/bin/osascript"
    private static let subprocessTimeoutSeconds: TimeInterval = 2.0

    /// Derived from `assets/nowPlaying.jxa` in the `media-remote` crate (MIT).
    private static let nowPlayingScript = """
    function run() {
      const MediaRemote = $.NSBundle.bundleWithPath(
        "/System/Library/PrivateFrameworks/MediaRemote.framework/",
      );
      MediaRemote.load;

      const MRNowPlayingRequest = $.NSClassFromString("MRNowPlayingRequest");

      const client = MRNowPlayingRequest.localNowPlayingPlayerPath.client;
      const clientConverted = {
        bundleIdentifier: client.bundleIdentifier.js,
        parentApplicationBundleIdentifier:
          client.parentApplicationBundleIdentifier.js,
      };

      const infoDict = MRNowPlayingRequest.localNowPlayingItem.nowPlayingInfo;
      const infoConverted = {};
      for (const key in infoDict.js) {
        const value = infoDict.valueForKey(key).js;
        if (typeof value !== "object") {
          infoConverted[key] = value;
        } else if (value && typeof value.getTime === "function") {
          try {
            infoConverted[key] = value.getTime();
          } catch (e) {
            infoConverted[key] = value.toString();
          }
        } else {
          infoConverted[key] = value.toString();
        }
      }

      return JSON.stringify({
        isPlaying: MRNowPlayingRequest.localIsPlaying,
        client: clientConverted,
        info: infoConverted,
      });
    }
    """

    /// `true` / `false` when stdout parses as JSON with `isPlaying`; `nil` if `osascript` failed or payload unusable.
    static func snapshotPlayingState() -> Bool? {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: osascriptPath)
      process.arguments = ["-l", "JavaScript"]
      let inPipe = Pipe()
      let outPipe = Pipe()
      let errPipe = Pipe()
      process.standardInput = inPipe
      process.standardOutput = outPipe
      process.standardError = errPipe

      let done = DispatchSemaphore(value: 0)
      process.terminationHandler = { _ in done.signal() }

      do {
        try process.run()
      } catch {
        AppLogger.general.warning("MediaRemote JXA: failed to launch osascript: \(error.localizedDescription)")
        return nil
      }

      inPipe.fileHandleForWriting.write(Data(nowPlayingScript.utf8))
      try? inPipe.fileHandleForWriting.close()

      let waitResult = done.wait(timeout: .now() + subprocessTimeoutSeconds)
      if waitResult == .timedOut {
        process.terminate()
        _ = done.wait(timeout: .now() + 1)
        AppLogger.general.warning("MediaRemote JXA: osascript timed out")
        return nil
      }

      guard process.terminationStatus == 0 else {
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let errText = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        AppLogger.general.warning(
          "MediaRemote JXA: osascript exit \(process.terminationStatus)\(errText.isEmpty ? "" : " — \(errText)")"
        )
        return nil
      }

      let data = outPipe.fileHandleForReading.readDataToEndOfFile()
      guard !data.isEmpty else {
        AppLogger.general.warning("MediaRemote JXA: empty stdout")
        return nil
      }

      let trimmed =
        String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      guard let jsonData = trimmed.data(using: .utf8) else {
        AppLogger.general.warning("MediaRemote JXA: stdout not UTF-8")
        return nil
      }

      guard let root = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
        let snippet = String(trimmed.prefix(200))
        AppLogger.general.warning("MediaRemote JXA: stdout not JSON object (snippet: \(snippet, privacy: .public))")
        return nil
      }

      if let playing = root["isPlaying"] as? Bool {
        if SettingsManager.shared.enableDetailedLogging {
          AppLogger.general.info("MediaRemote JXA: isPlaying=\(playing, privacy: .public)")
        }
        return playing
      }
      if let num = root["isPlaying"] as? NSNumber {
        let playing = num.boolValue
        if SettingsManager.shared.enableDetailedLogging {
          AppLogger.general.info("MediaRemote JXA: isPlaying=\(playing, privacy: .public) (NSNumber)")
        }
        return playing
      }

      if SettingsManager.shared.enableDetailedLogging {
        AppLogger.general.info("MediaRemote JXA: JSON missing \"isPlaying\" key")
      }
      return nil
    }
  }

#else

  enum MediaRemoteJXAAdapter {
    static func snapshotPlayingState() -> Bool? { nil }
  }

#endif
