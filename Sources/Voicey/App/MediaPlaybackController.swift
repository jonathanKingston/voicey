import AppKit
import CoreGraphics

final class MediaPlaybackController: MediaPlaybackControlling {
  static let shared = MediaPlaybackController()

  private var didPauseForTranscription = false

  private init() {}

  func pauseForTranscription() {
    guard !didPauseForTranscription else { return }

    didPauseForTranscription = true
    postPlayPauseKey()
    AppLogger.general.info("Requested media pause for transcription")
  }

  func noteExternalPauseForTranscription() {
    guard !didPauseForTranscription else { return }

    didPauseForTranscription = true
    AppLogger.general.info("Tracking media pause from transcription trigger")
  }

  func reassertPauseDuringTranscription() {
    guard didPauseForTranscription else { return }

    postPlayPauseKey()
    AppLogger.general.info("Reasserted media pause during transcription")
  }

  func resumeAfterTranscription() {
    guard didPauseForTranscription else { return }

    didPauseForTranscription = false
    postPlayPauseKey()
    AppLogger.general.info("Requested media resume after transcription")
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
