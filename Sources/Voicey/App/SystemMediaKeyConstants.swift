import AppKit
import CoreGraphics

enum SystemMediaKeyConstants {
  // AppKit exposes the event type but not semantic names for auxiliary media-key events.
  static let auxiliaryControlButtonSubtype = Int16(8)  // NX_SUBTYPE_AUX_CONTROL_BUTTONS
  static let playPauseKeyCode = Int32(16)  // NX_KEYTYPE_PLAY
  static let keyDownState = UInt32(0xA)
  static let keyUpState = UInt32(0xB)
  static let systemDefinedEventMask =
    CGEventMask(1) << UInt64(NSEvent.EventType.systemDefined.rawValue)
}
