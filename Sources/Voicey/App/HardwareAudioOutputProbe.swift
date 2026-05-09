import CoreAudio

/// HAL snapshot: whether something is streaming to the default **output** device.
///
/// Used only for **diagnostics** when Advanced → detailed logging is on (`MediaPlaybackController` logs `raw`).
/// Pause gating uses Media Remote (JXA / in-process), not this probe.
enum HardwareAudioOutputProbe {

  static func isDefaultOutputDeviceRunningSomewhere() -> Bool {
    let systemObject = AudioObjectID(kAudioObjectSystemObject)

    var deviceID = AudioDeviceID(kAudioObjectUnknown)
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)

    guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &dataSize, &deviceID) == noErr else {
      return false
    }
    guard deviceID != kAudioObjectUnknown else { return false }

    address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )

    guard AudioObjectHasProperty(deviceID, &address) else { return false }

    var running: UInt32 = 0
    dataSize = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &running) == noErr else {
      return false
    }
    return running != 0
  }
}
