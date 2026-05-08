import AppKit
import CoreGraphics

final class MediaPlaybackController: MediaPlaybackControlling {
  static let shared = MediaPlaybackController()

  /// True when transcription should be followed by a synthetic play/pause toggle to restore media.
  private var expectsSyntheticResumeToggle = false

  private init() {}

  func pauseForTranscription() {
    guard !expectsSyntheticResumeToggle else {
      AppLogger.general.info("pauseForTranscription: skipped (already expects resume toggle)")
      debugPrint("pauseForTranscription: skipped (already expects resume toggle)", category: "MEDIA")
      return
    }

    let playing = Self.logPlaybackProbeContext(label: "pauseForTranscription")
    guard playing else {
      AppLogger.general.info("Skipping media pause; probes report nothing playing")
      debugPrint("Skipping media pause; probes report nothing playing", category: "MEDIA")
      return
    }

    expectsSyntheticResumeToggle = true
    AppLogger.general.info("pauseForTranscription: posting synthetic play/pause HID")
    debugPrint("pauseForTranscription: posting synthetic play/pause HID", category: "MEDIA")
    postPlayPauseKey()
    AppLogger.general.info("pauseForTranscription: finished posting HID; resume is armed")
  }

  func resumeAfterTranscription() {
    guard expectsSyntheticResumeToggle else {
      AppLogger.general.info("resumeAfterTranscription: skipped (resume not armed)")
      debugPrint("resumeAfterTranscription: skipped (resume not armed)", category: "MEDIA")
      return
    }

    expectsSyntheticResumeToggle = false
    AppLogger.general.info("resumeAfterTranscription: posting synthetic play/pause HID to restore")
    debugPrint("resumeAfterTranscription: posting synthetic play/pause HID to restore", category: "MEDIA")
    postPlayPauseKey()
    AppLogger.general.info("resumeAfterTranscription: finished posting HID")
  }

  /// Logs probe breakdown (MediaRemote on direct builds; Music/Spotify AppleScript) and returns combined playing.
  @discardableResult
  private static func logPlaybackProbeContext(label: String) -> Bool {
    let mediaRemote = MediaRemotePlaybackProbe.isMediaPlaying()
    let music = isAppleMusicPlaying()
    let spotify = isSpotifyPlaying()
    let combined = mediaRemote || music || spotify

    #if !VOICEY_DIRECT_DISTRIBUTION
      let buildNote =
        " MediaRemote API is not compiled into this binary; build with VOICEY_DIRECT=1 for system Now Playing (Firefox, etc.)."
    #else
      let buildNote = ""
    #endif

    AppLogger.general.info(
      "[\(label)] playback probes — MediaRemote: \(mediaRemote), Music.app: \(music), Spotify: \(spotify) → combined: \(combined).\(buildNote)"
    )
    debugPrint(
      "[\(label)] MR=\(mediaRemote) Music=\(music) Spotify=\(spotify) → \(combined)\(buildNote)",
      category: "MEDIA"
    )
    return combined
  }

  private static func isAppleMusicPlaying() -> Bool {
    isScriptableAppReportingPlaying(
      bundleID: "com.apple.Music",
      scriptApplicationName: "Music"
    )
  }

  private static func isSpotifyPlaying() -> Bool {
    isScriptableAppReportingPlaying(
      bundleID: "com.spotify.client",
      scriptApplicationName: "Spotify"
    )
  }

  /// `MPMusicPlayerController` is unavailable on macOS; use AppleScript when the app is running.
  private static func isScriptableAppReportingPlaying(bundleID: String, scriptApplicationName: String) -> Bool {
    guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first != nil else {
      return false
    }
    let source = """
    tell application "\(scriptApplicationName)" to return player state as string
    """
    guard let script = NSAppleScript(source: source) else { return false }
    let state = script.executeAndReturnError(nil).stringValue ?? "(nil)"
    let playing = state == "playing"
    if SettingsManager.shared.enableDetailedLogging {
      AppLogger.general.info(
        "AppleScript \(scriptApplicationName): player state=\"\(state, privacy: .public)\" playing=\(playing)"
      )
      debugPrint("AppleScript \(scriptApplicationName): state=\(state) playing=\(playing)", category: "MEDIA")
    }
    return playing
  }

  private func postPlayPauseKey() {
    postMediaKey(state: SystemMediaKeyConstants.keyDownState)
    postMediaKey(state: SystemMediaKeyConstants.keyUpState)
  }

  private func postMediaKey(state: UInt32) {
    let data1 =
      (UInt32(SystemMediaKeyConstants.playPauseKeyCode) << 16)
      | (state << 8)

    guard
      let nsEvent = NSEvent.otherEvent(
        with: .systemDefined,
        location: .zero,
        modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        subtype: SystemMediaKeyConstants.auxiliaryControlButtonSubtype,
        data1: Int(data1),
        data2: -1
      ),
      let cgEvent = nsEvent.cgEvent
    else {
      AppLogger.general.warning("Unable to create media key event")
      return
    }

    cgEvent.setIntegerValueField(
      CGEventField.eventSourceUserData,
      value: SystemMediaKeyConstants.voiceySyntheticEventUserData
    )
    cgEvent.post(tap: CGEventTapLocation.cghidEventTap)
  }
}
