# App Sandbox Fix for Voicey

## Problem Summary

Voicey previously had **App Sandbox disabled** (`com.apple.security.app-sandbox` = `false`). This prevented App Store submission, as Apple requires all Mac App Store apps to be sandboxed.

### Why Sandbox Breaks Current Functionality

The current auto-paste feature uses two methods that are **blocked by App Sandbox**:

1. **AppleScript System Events** (line 25-29 of `KeyboardSimulator.swift`):
   ```swift
   tell application "System Events"
       keystroke "v" using command down
   end tell
   ```
   This requires scripting access to System Events, which sandboxed apps cannot have.

2. **CGEvent Keyboard Simulation** (line 48-73 of `KeyboardSimulator.swift`):
   ```swift
   CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
   event.post(tap: .cgSessionEventTap)
   ```
   CGEvents posted to `.cgSessionEventTap` require accessibility permissions that don't work properly in sandboxed apps.

## Solution: Clipboard-Only Mode

The fix removes the auto-paste functionality entirely and switches to a clipboard-only workflow:

1. **Transcribe audio** → same as before
2. **Copy text to clipboard** → already works in sandbox
3. **Show notification** → "Transcription copied! Press ⌘V to paste"
4. **User pastes manually** → standard macOS behavior

### Benefits
- ✅ App Store compliant
- ✅ Simpler, more predictable behavior
- ✅ No Apple Events automation required (Accessibility is optional for auto-paste)
- ✅ Works with all apps, including those that block synthetic keyboard events

### Trade-offs
- ❌ User must press ⌘V manually (one extra keystroke)
- ❌ Slightly longer workflow

## Files Changed

### 1. `Sources/Voicey/Output/KeyboardSimulator.swift`
- **Remove** `simulatePaste()` method
- **Remove** `simulatePasteViaCGEvent()` method
- **Keep** `typeText()` for potential future use (or remove entirely)
- File may be deleted entirely if not needed

### 2. `Sources/Voicey/Output/OutputManager.swift`
- **Remove** `OutputMode` enum (paste modes no longer meaningful)
- **Simplify** `deliver()` to only copy to clipboard
- **Remove** app activation/focus logic (no longer needed)
- **Add** notification after copy

### 3. `Sources/Voicey/Utilities/Notifications.swift`
- **Add** `showTranscriptionCopied()` method

### 4. `Sources/Voicey/UI/SettingsView.swift`
- **Remove** Output Mode picker from `GeneralSettingsView`

### 5. `Sources/Voicey/Utilities/Settings.swift`
- **Remove** `outputMode` property

### 6. `Voicey.entitlements`
- **Change** `com.apple.security.app-sandbox` from `false` to `true`

## Implementation Steps

1. Add the "transcription copied" notification
2. Simplify OutputManager to clipboard-only
3. Remove KeyboardSimulator or gut its paste methods
4. Remove OutputMode from Settings and SettingsView
5. Enable App Sandbox in entitlements
6. Test build and run

## Implementation Status: ✅ Complete

All changes have been implemented and the app builds successfully.

## Testing Checklist

After implementation:
- [x] App builds successfully with sandbox enabled
- [x] Recording with Ctrl+V works
- [x] Transcription completes
- [x] Text is copied to clipboard
- [x] Notification appears: "Transcription copied! Press ⌘V to paste"
- [ ] Manual paste (⌘V) works in target application (requires user testing)
- [x] Settings view no longer shows Output Mode picker

## Changes Made

1. **Deleted** `Sources/Voicey/Output/KeyboardSimulator.swift` - sandbox-incompatible
2. **Simplified** `Sources/Voicey/Output/OutputManager.swift` - clipboard-only flow
3. **Added** `showTranscriptionCopied()` to `NotificationManager` and protocol
4. **Removed** `OutputMode` enum and all references
5. **Updated** `GeneralSettingsView` - removed Output Mode picker
6. **Enabled** sandbox in `Voicey.entitlements` and trimmed entitlements to the minimum set needed
