import AppKit
import CoreGraphics

final class MediaPlaybackController: MediaPlaybackControlling {
  static let shared = MediaPlaybackController()

  /// True when transcription should be followed by a synthetic play/pause toggle to restore media.
  private var expectsSyntheticResumeToggle = false

  private init() {}

  func pauseForTranscription() {
    guard !expectsSyntheticResumeToggle else { return }

    guard Self.isLikelySystemMediaPlaying() else {
      AppLogger.general.info("Skipping media pause; no known playback source is playing")
      return
    }

    expectsSyntheticResumeToggle = true
    postPlayPauseKey()
    AppLogger.general.info("Requested media pause for transcription")
  }

  func resumeAfterTranscription() {
    guard expectsSyntheticResumeToggle else { return }

    expectsSyntheticResumeToggle = false
    postPlayPauseKey()
    AppLogger.general.info("Requested media resume after transcription")
  }

  /// Direct builds probe MediaRemote (system Now Playing); App Store builds use scriptable players.
  /// Hardware play/pause taps are not used here: each press is a toggle edge, not a trustworthy “is playing” signal.
  private static func isLikelySystemMediaPlaying() -> Bool {
    if MediaRemotePlaybackProbe.isMediaPlaying() { return true }
    if isAppleMusicPlaying() { return true }
    if isSpotifyPlaying() { return true }
    return false
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
    return script.executeAndReturnError(nil).stringValue == "playing"
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
