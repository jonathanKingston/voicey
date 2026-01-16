import Foundation
import Carbon.HIToolbox
import AppKit
import os

/// Manages global hotkey registration and handling
/// Note: This works alongside KeyboardShortcuts package for a more robust solution
final class HotkeyManager {
    static let shared = HotkeyManager()
    
    private var eventHandler: EventHandlerRef?
    private var hotkeyRef: EventHotKeyRef?
    private var callback: (() -> Void)?
    
    init() {}
    
    deinit {
        unregisterHotkey()
    }
    
    /// Register a global hotkey with the system
    /// - Parameters:
    ///   - keyCode: Virtual key code (e.g., kVK_ANSI_C for 'C')
    ///   - modifiers: Modifier flags (e.g., controlKey)
    ///   - callback: Closure to execute when hotkey is pressed
    func registerHotkey(keyCode: UInt32, modifiers: UInt32, callback: @escaping () -> Void) {
        unregisterHotkey()
        
        self.callback = callback
        
        // Set up event type spec
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        
        // Install event handler
        let handlerResult = InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, userData) -> OSStatus in
                guard let userData = userData else { return OSStatus(eventNotHandledErr) }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                manager.callback?()
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        
        guard handlerResult == noErr else {
            AppLogger.general.error("Failed to install event handler: \(handlerResult)")
            return
        }
        
        // Register hotkey
        let hotkeyID = EventHotKeyID(signature: OSType(0x564F4943), id: 1) // "VOIC"
        
        let registerResult = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotkeyID,
            GetApplicationEventTarget(),
            0,
            &hotkeyRef
        )
        
        if registerResult != noErr {
            AppLogger.general.error("Failed to register hotkey: \(registerResult)")
        }
    }
    
    /// Unregister the current hotkey
    func unregisterHotkey() {
        if let hotkeyRef = hotkeyRef {
            UnregisterEventHotKey(hotkeyRef)
            self.hotkeyRef = nil
        }
        
        if let eventHandler = eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
        
        callback = nil
    }
    
    /// Check if a hotkey combination conflicts with system shortcuts
    static func checkForConflict(keyCode: UInt32, modifiers: UInt32) -> Bool {
        // Known system shortcuts that might conflict
        let systemShortcuts: [(keyCode: UInt32, modifiers: UInt32, description: String)] = [
            (UInt32(kVK_ANSI_C), UInt32(cmdKey), "Copy (⌘C)"),
            (UInt32(kVK_ANSI_V), UInt32(cmdKey), "Paste (⌘V)"),
            (UInt32(kVK_ANSI_X), UInt32(cmdKey), "Cut (⌘X)"),
            (UInt32(kVK_ANSI_A), UInt32(cmdKey), "Select All (⌘A)"),
            (UInt32(kVK_ANSI_Z), UInt32(cmdKey), "Undo (⌘Z)"),
            (UInt32(kVK_Tab), UInt32(cmdKey), "Switch App (⌘Tab)"),
            (UInt32(kVK_Space), UInt32(cmdKey), "Spotlight (⌘Space)"),
        ]
        
        for shortcut in systemShortcuts {
            if shortcut.keyCode == keyCode && shortcut.modifiers == modifiers {
                return true
            }
        }
        
        return false
    }
}

// MARK: - Key Code Utilities

extension HotkeyManager {
    /// Convert a character to its virtual key code
    static func keyCode(for character: Character) -> UInt32? {
        let keyCodeMap: [Character: UInt32] = [
            "a": UInt32(kVK_ANSI_A), "b": UInt32(kVK_ANSI_B), "c": UInt32(kVK_ANSI_C),
            "d": UInt32(kVK_ANSI_D), "e": UInt32(kVK_ANSI_E), "f": UInt32(kVK_ANSI_F),
            "g": UInt32(kVK_ANSI_G), "h": UInt32(kVK_ANSI_H), "i": UInt32(kVK_ANSI_I),
            "j": UInt32(kVK_ANSI_J), "k": UInt32(kVK_ANSI_K), "l": UInt32(kVK_ANSI_L),
            "m": UInt32(kVK_ANSI_M), "n": UInt32(kVK_ANSI_N), "o": UInt32(kVK_ANSI_O),
            "p": UInt32(kVK_ANSI_P), "q": UInt32(kVK_ANSI_Q), "r": UInt32(kVK_ANSI_R),
            "s": UInt32(kVK_ANSI_S), "t": UInt32(kVK_ANSI_T), "u": UInt32(kVK_ANSI_U),
            "v": UInt32(kVK_ANSI_V), "w": UInt32(kVK_ANSI_W), "x": UInt32(kVK_ANSI_X),
            "y": UInt32(kVK_ANSI_Y), "z": UInt32(kVK_ANSI_Z),
            "0": UInt32(kVK_ANSI_0), "1": UInt32(kVK_ANSI_1), "2": UInt32(kVK_ANSI_2),
            "3": UInt32(kVK_ANSI_3), "4": UInt32(kVK_ANSI_4), "5": UInt32(kVK_ANSI_5),
            "6": UInt32(kVK_ANSI_6), "7": UInt32(kVK_ANSI_7), "8": UInt32(kVK_ANSI_8),
            "9": UInt32(kVK_ANSI_9),
        ]
        return keyCodeMap[character]
    }
    
    /// Convert Carbon modifier flags to Cocoa modifier flags
    static func cocoaModifiers(from carbonModifiers: UInt32) -> NSEvent.ModifierFlags {
        var modifiers: NSEvent.ModifierFlags = []
        if carbonModifiers & UInt32(cmdKey) != 0 { modifiers.insert(.command) }
        if carbonModifiers & UInt32(shiftKey) != 0 { modifiers.insert(.shift) }
        if carbonModifiers & UInt32(optionKey) != 0 { modifiers.insert(.option) }
        if carbonModifiers & UInt32(controlKey) != 0 { modifiers.insert(.control) }
        return modifiers
    }
    
    /// Convert Cocoa modifier flags to Carbon modifier flags
    static func carbonModifiers(from cocoaModifiers: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if cocoaModifiers.contains(.command) { modifiers |= UInt32(cmdKey) }
        if cocoaModifiers.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if cocoaModifiers.contains(.option) { modifiers |= UInt32(optionKey) }
        if cocoaModifiers.contains(.control) { modifiers |= UInt32(controlKey) }
        return modifiers
    }
}
