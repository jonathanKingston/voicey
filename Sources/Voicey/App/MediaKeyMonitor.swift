import AppKit
import CoreGraphics
import Foundation

final class MediaKeyMonitor {
  private struct MediaKeyEvent {
    let keyCode: Int32
    let isKeyDown: Bool
  }

  private let onPlayPausePressed: @MainActor () -> Void
  private var eventTap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?

  init(onPlayPausePressed: @escaping @MainActor () -> Void) {
    self.onPlayPausePressed = onPlayPausePressed
  }

  deinit {
    stop()
  }

  func start() {
    guard eventTap == nil else { return }

    let userInfo = Unmanaged.passUnretained(self).toOpaque()
    guard
      let eventTap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .listenOnly,
        eventsOfInterest: SystemMediaKeyConstants.systemDefinedEventMask,
        callback: Self.handleEventTap,
        userInfo: userInfo
      )
    else {
      AppLogger.general.warning(
        "Media key monitoring unavailable; could not create event tap"
      )
      return
    }

    guard let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
    else {
      CFMachPortInvalidate(eventTap)
      AppLogger.general.warning(
        "Media key monitoring unavailable; could not create event tap run-loop source"
      )
      return
    }

    CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
    CGEvent.tapEnable(tap: eventTap, enable: true)

    self.eventTap = eventTap
    self.runLoopSource = runLoopSource

    AppLogger.general.info("Started media key monitoring")
  }

  func stop() {
    guard let eventTap else { return }

    CGEvent.tapEnable(tap: eventTap, enable: false)
    CFMachPortInvalidate(eventTap)

    if let runLoopSource {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
    }

    self.runLoopSource = nil
    self.eventTap = nil

    AppLogger.general.info("Stopped media key monitoring")
  }

  private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      if let eventTap {
        CGEvent.tapEnable(tap: eventTap, enable: true)
      }
      return Unmanaged.passUnretained(event)
    }

    let isVoiceySyntheticEvent =
      event.getIntegerValueField(CGEventField.eventSourceUserData)
      == SystemMediaKeyConstants.voiceySyntheticEventUserData
    if isVoiceySyntheticEvent {
      return Unmanaged.passUnretained(event)
    }

    guard let nsEvent = NSEvent(cgEvent: event),
      let mediaKeyEvent = Self.mediaKeyEvent(from: nsEvent),
      mediaKeyEvent.keyCode == SystemMediaKeyConstants.playPauseKeyCode,
      mediaKeyEvent.isKeyDown
    else {
      return Unmanaged.passUnretained(event)
    }

    AppLogger.general.info("Play/pause media key pressed")

    Task { @MainActor in
      onPlayPausePressed()
    }

    return Unmanaged.passUnretained(event)
  }

  private static func mediaKeyEvent(from event: NSEvent) -> MediaKeyEvent? {
    guard event.type == .systemDefined,
      event.subtype.rawValue == SystemMediaKeyConstants.auxiliaryControlButtonSubtype
    else {
      return nil
    }

    let data1 = UInt32(truncatingIfNeeded: event.data1)
    let keyCode = Int32((data1 & 0xFFFF_0000) >> 16)
    let keyState = (data1 & 0x0000_FF00) >> 8

    return MediaKeyEvent(
      keyCode: keyCode,
      isKeyDown: keyState == SystemMediaKeyConstants.keyDownState
    )
  }

  private static let handleEventTap: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else {
      return Unmanaged.passUnretained(event)
    }

    let monitor = Unmanaged<MediaKeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    return monitor.handleEvent(type: type, event: event)
  }
}
