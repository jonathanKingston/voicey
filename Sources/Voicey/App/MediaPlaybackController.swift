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

    postMediaRemoteThenHID(context: "pauseForTranscription", resume: false)
    expectsSyntheticResumeToggle = true
    AppLogger.general.info("pauseForTranscription: finished media pause request; resume is armed")
  }

  func resumeAfterTranscription() {
    guard expectsSyntheticResumeToggle else {
      AppLogger.general.info("resumeAfterTranscription: skipped (resume not armed)")
      debugPrint("resumeAfterTranscription: skipped (resume not armed)", category: "MEDIA")
      return
    }

    expectsSyntheticResumeToggle = false
    postMediaRemoteThenHID(context: "resumeAfterTranscription", resume: true)
    AppLogger.general.info("resumeAfterTranscription: finished media resume request")
  }

  /// Logs probe breakdown (MediaRemote when compiled; optional default output device hint) and returns combined playing.
  @discardableResult
  private static func logPlaybackProbeContext(label: String) -> Bool {
    let mediaRemote = MediaRemotePlaybackProbe.isMediaPlaying()
    let useOutputHint = SettingsManager.shared.mediaPauseUseOutputDeviceActivityHint
    let detailed = SettingsManager.shared.enableDetailedLogging
    let outputRaw: Bool
    if useOutputHint || detailed {
      outputRaw = HardwareAudioOutputProbe.isDefaultOutputDeviceRunningSomewhere()
    } else {
      outputRaw = false
    }
    let outputIO = useOutputHint && outputRaw
    let combined = mediaRemote || outputIO

    #if !VOICEY_DIRECT_DISTRIBUTION && !VOICEY_MEDIA_REMOTE_PROBE
      let buildNote =
        " MediaRemote probe not compiled in; use `make build` / Xcode Debug with VOICEY_MEDIA_REMOTE_PROBE, or `make build-direct` for full direct build."
    #else
      let buildNote = ""
    #endif

    let rawNote = (!useOutputHint && !detailed) ? " (HAL not queried; hint off)" : ""
    AppLogger.general.info(
      "[\(label)] playback probes — MediaRemote: \(mediaRemote), defaultOutputIO(raw: \(outputRaw), used: \(outputIO))\(rawNote) → combined: \(combined).\(buildNote)"
    )
    debugPrint(
      "[\(label)] MR=\(mediaRemote) outIO=\(outputIO) raw=\(outputRaw) hint=\(useOutputHint) → \(combined)\(buildNote)",
      category: "MEDIA"
    )
    return combined
  }

  /// At most **one** `MRMediaRemoteSendCommand` before HID. Chaining pause + toggle (each ~0.35s timeout)
  /// could still enqueue two daemon actions even when callbacks time out, which stacks with the HID toggle
  /// and produces pause → immediate resume → pause on the final resume toggle.
  private func postMediaRemoteThenHID(context: String, resume: Bool) {
    #if VOICEY_DIRECT_DISTRIBUTION || VOICEY_MEDIA_REMOTE_PROBE
      if resume {
        if MediaRemoteCommandSender.sendPlayAndWait() {
          AppLogger.general.info("\(context): MRMediaRemoteSendCommand(play) reported success")
          debugPrint("\(context): MR play ok", category: "MEDIA")
          return
        }
        if MediaRemotePlaybackProbe.isPlayingEmbeddedMediaRemoteSnapshot() {
          AppLogger.general.info(
            "\(context): MR play did not report success but embedded MR probe reports playing; skipping HID (avoids pause-toggle stacking)"
          )
          debugPrint("\(context): skip HID resume; embedded MR already playing", category: "MEDIA")
          return
        }
      } else {
        if MediaRemoteCommandSender.sendPauseAndWait() {
          AppLogger.general.info("\(context): MRMediaRemoteSendCommand(pause) reported success")
          debugPrint("\(context): MR pause ok", category: "MEDIA")
          return
        }
        if !MediaRemotePlaybackProbe.isPlayingEmbeddedMediaRemoteSnapshot() {
          AppLogger.general.info(
            "\(context): MR pause did not report success but embedded MR probe reports not playing; skipping HID (avoids play-toggle stacking)"
          )
          debugPrint("\(context): skip HID pause; embedded MR already paused", category: "MEDIA")
          return
        }
      }
      AppLogger.general.info("\(context): MR SendCommand unavailable or failed; posting synthetic play/pause HID")
      debugPrint("\(context): MR fallback HID", category: "MEDIA")
    #else
      AppLogger.general.info("\(context): posting synthetic play/pause HID (MR commands not compiled in)")
      debugPrint("\(context): HID only (no MR send)", category: "MEDIA")
    #endif
    postPlayPauseKey()
  }

  /// Synthetic NX play/pause (legacy fallback).
  /// Runs on the main queue and splits key-down / key-up across run-loop turns.
  private func postPlayPauseKey() {
    let postUp: () -> Void = { [weak self] in
      self?.postMediaKey(state: SystemMediaKeyConstants.keyUpState)
    }
    let postDownAndScheduleUp: () -> Void = { [weak self] in
      self?.postMediaKey(state: SystemMediaKeyConstants.keyDownState)
      DispatchQueue.main.async(execute: postUp)
    }
    if Thread.isMainThread {
      postDownAndScheduleUp()
    } else {
      DispatchQueue.main.async(execute: postDownAndScheduleUp)
    }
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

    cgEvent.post(tap: CGEventTapLocation.cghidEventTap)
  }
}
