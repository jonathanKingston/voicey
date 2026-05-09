import CoreAudio

/// HAL-based hint that something is streaming to the default **output** device.
///
/// Prefer the JXA / MediaRemote snapshot when available; this probe is an optional coarse fallback.
/// MediaRemote often omits browser/tab audio (e.g. Firefox) while Control Center still shows Now Playing.
/// `kAudioDevicePropertyDeviceIsRunningSomewhere` is true when any client holds active I/O on that device, which
/// usually includes normal music playback. It can also be true for calls, games, or other output—prefer MediaRemote
/// when it works, and treat this as a broad fallback for pause-before-transcribe.
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
