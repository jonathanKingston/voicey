# App Store Submission Checklist

This document outlines what's needed to submit Voicey to the Apple App Store.

## ⚠️ Important: Architectural Decision Required

Before proceeding, you must choose a distribution strategy. The app's current design (global hotkeys + auto-paste) **conflicts with App Sandbox requirements**.

### Option A: App Store Distribution (Requires UX Changes)
- Must enable App Sandbox
- Auto-paste won't work under sandbox (CGEvent blocked)
- User will need to manually paste (⌘V) after transcription

### Option B: Direct Distribution (Notarized, Non-App Store)
- Keeps full functionality (auto-paste)
- Distribute via website, Homebrew, etc.
- No App Store listing

**Current setup supports both:** The codebase builds for either target using different entitlements files.

---

## Critical Blockers

### 1. Enable App Sandbox

**Status:** ✅ Completed

**Entitlements (`Voicey.entitlements`):**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <key>com.apple.security.device.audio-input</key>
    <true/>
    <key>com.apple.security.network.client</key>
    <true/>
</dict>
</plist>
```

**Notes:**
- Models are stored under Application Support; no broad file access entitlements are required.
- Auto-paste setting exists in UI but won't function under sandbox (CGEvent is blocked).

### 2. Output Mechanism

**Status:** ✅ Completed

**Behavior for App Store build:**
1. Copy transcription to clipboard (works in sandbox)
2. Show system notification: "Transcription copied! Press ⌘V to paste"
3. User pastes manually

**Implementation:**
- `OutputManager` copies to clipboard and shows notification
- `KeyboardSimulator.swift` exists for direct distribution builds (sandbox disables CGEvent)
- Auto-paste toggle in settings will prompt for Accessibility but won't work under sandbox

### 3. Create App Icon

**Status:** ✅ Completed

**Current state:** `AppIcon.icns` is in `Voicey.app/Contents/Resources/`

**Required sizes:**
- 16x16, 16x16@2x (32px)
- 32x32, 32x32@2x (64px)
- 128x128, 128x128@2x (256px)
- 256x256, 256x256@2x (512px)
- 512x512, 512x512@2x (1024px)

**To generate icon from a 1024x1024 PNG:**
```bash
make icon SOURCE=path/to/icon_1024.png
```

This creates `AppIcon.icns` in the Resources folder.

### 4. Update Info.plist

**Status:** ✅ Completed

All required keys are present:

| Key | Value | Status |
|-----|-------|--------|
| `CFBundleIdentifier` | `work.voicey.Voicey` | ✅ |
| `CFBundleShortVersionString` | `1.0.0` | ✅ |
| `CFBundleVersion` | `1` | ✅ |
| `LSApplicationCategoryType` | `public.app-category.productivity` | ✅ |
| `CFBundleIconFile` | `AppIcon` | ✅ |
| `ITSAppUsesNonExemptEncryption` | `false` | ✅ |
| `NSMicrophoneUsageDescription` | ✅ Clear description | ✅ |

### 5. Set Up Code Signing

**Status:** ⏳ Pending (requires Apple Developer enrollment)

**Current state:** Ad-hoc signing (`codesign --sign -`)

**Required steps:**
1. Enroll in Apple Developer Program ($99/year) at https://developer.apple.com/programs/
2. Create certificates in Xcode or developer portal:
   - "3rd Party Mac Developer Application" (for App Store)
   - "3rd Party Mac Developer Installer" (for pkg)
3. Sign and package:

```bash
# Sign for App Store
make sign-appstore IDENTITY="3rd Party Mac Developer Application: Your Name (TEAM_ID)"

# Create installer package
make package-appstore \
    IDENTITY="3rd Party Mac Developer Application: Your Name (TEAM_ID)" \
    INSTALLER_IDENTITY="3rd Party Mac Developer Installer: Your Name (TEAM_ID)"
```

---

## App Store Connect Setup

### Account Requirements
- [ ] Apple Developer Program membership active
- [ ] App Store Connect access configured

### Create App Record
1. Go to https://appstoreconnect.apple.com
2. My Apps → "+" → New App
3. Fill in:
   - Platform: macOS
   - Name: Voicey
   - Primary Language: English
   - Bundle ID: `work.voicey.Voicey`
   - SKU: `voicey-macos-1`

### Required Metadata
- [ ] **App Name:** Voicey (or available alternative)
- [ ] **Subtitle:** Up to 30 characters
- [ ] **Description:** Up to 4000 characters explaining the app
- [ ] **Keywords:** Up to 100 characters, comma-separated
- [ ] **What's New:** Release notes for this version
- [ ] **Privacy Policy URL:** Required (host on your website)
- [ ] **Support URL:** Required
- [ ] **Marketing URL:** Optional

### Screenshots
Required sizes for Mac App Store:
- [ ] 1280 × 800 pixels, or
- [ ] 1440 × 900 pixels, or
- [ ] 2560 × 1600 pixels, or
- [ ] 2880 × 1800 pixels

Minimum 1 screenshot, maximum 10.

### App Review Information
- [ ] Contact first name
- [ ] Contact last name
- [ ] Contact phone number
- [ ] Contact email
- [ ] Demo account (if applicable)
- [ ] Notes for reviewer (explain accessibility usage)

### Age Rating
Complete the questionnaire covering:
- [ ] Violence
- [ ] Sexual content
- [ ] Profanity
- [ ] Drug use
- [ ] Gambling
- [ ] Horror themes

For Voicey, likely all "None" → Rating: 4+

### Pricing
- [ ] Choose price tier (or Free)
- [ ] Select availability by country/region

---

## Build & Upload Process

### Using Xcode (Recommended)

1. Open in Xcode:
   ```bash
   make xcode
   ```
   This opens `Package.swift` directly — Xcode handles Swift packages natively.

2. In Xcode:
   - Set Team in Signing & Capabilities
   - Verify App Sandbox is enabled
   - Verify entitlements match `Voicey.entitlements`
   - Set version/build numbers

3. Archive:
   - Product → Archive
   - Validate App
   - Distribute App → App Store Connect

### Using Command Line

1. Build and sign:
   ```bash
   make sign-appstore IDENTITY="3rd Party Mac Developer Application: Your Name (TEAM_ID)"
   ```

2. Create installer package:
   ```bash
   make package-appstore \
       IDENTITY="3rd Party Mac Developer Application: Your Name (TEAM_ID)" \
       INSTALLER_IDENTITY="3rd Party Mac Developer Installer: Your Name (TEAM_ID)"
   ```

3. Upload via Transporter app or:
   ```bash
   xcrun altool --upload-app -f Voicey.pkg -t macos \
       -u "your@email.com" -p "app-specific-password"
   ```

---

## Pre-Submission Checklist

### Code
- [x] App Sandbox enabled
- [x] Entitlements justified and minimal
- [x] Info.plist has all required keys
- [x] Usage descriptions are clear and accurate
- [ ] No private API usage (verify with `nm` or App Store validation)
- [ ] No hardcoded test data or debug code

### Assets
- [x] App icon in all required sizes
- [ ] Screenshots prepared
- [ ] No placeholder images

### App Store Connect
- [ ] App record created
- [ ] All metadata filled in
- [ ] Screenshots uploaded
- [ ] Privacy policy URL active
- [ ] Pricing configured

### Testing
- [ ] App runs correctly with sandbox enabled
- [ ] All features work as expected
- [ ] Tested on minimum supported macOS (13.0)
- [ ] Tested on latest macOS

---

## Reviewer Notes Template

When submitting, include notes for the App Review team:

```
Voicey is a voice-to-text transcription app that runs entirely on-device 
using Apple's CoreML. 

PERMISSIONS USED:
- Microphone: Required to capture voice for transcription
- Network: Used only for downloading AI models from Hugging Face on first launch

The app does not collect any user data. All transcription happens locally 
on the device.

To test:
1. Launch the app (appears in menubar)
2. Grant microphone permission when prompted
3. Download a model when prompted (recommend "Large v3 Turbo")
4. Press Ctrl+V to start recording
5. Speak a sentence
6. Press Ctrl+V again to transcribe
7. Text is copied to clipboard - press ⌘V to paste
```

---

## Alternative: Direct Distribution (Non-App Store)

If you choose to distribute outside the App Store to keep full auto-paste functionality:

### 1. Build with Direct Distribution Entitlements

```bash
make bundle-direct
```

This uses `VoiceyDirect.entitlements` (sandbox disabled) and `Info.direct.plist`.

### 2. Sign and Notarize

```bash
# Sign for notarization
make sign-direct DEVELOPER_ID="Developer ID Application: Your Name (TEAM_ID)"

# Notarize and create DMG
make notarize \
    APPLE_ID="your@email.com" \
    TEAM_ID="XXXXXXXXXX" \
    APP_PASSWORD="xxxx-xxxx-xxxx-xxxx"

# Or create DMG in one step (includes notarization)
make dmg \
    APPLE_ID="your@email.com" \
    TEAM_ID="XXXXXXXXXX" \
    APP_PASSWORD="xxxx-xxxx-xxxx-xxxx"
```

### 3. Distribution Channels
- Host on GitHub Releases
- Add to Homebrew Cask
- Distribute via your website

---

## Quick Reference: Make Targets

| Target | Description |
|--------|-------------|
| `make bundle` | Create app bundle (App Store entitlements) |
| `make bundle-direct` | Create app bundle (direct distribution) |
| `make sign-appstore IDENTITY=...` | Sign for App Store |
| `make package-appstore IDENTITY=... INSTALLER_IDENTITY=...` | Create .pkg |
| `make sign-direct DEVELOPER_ID=...` | Sign for notarization |
| `make notarize APPLE_ID=... TEAM_ID=... APP_PASSWORD=...` | Notarize app |
| `make dmg ...` | Create notarized DMG |
| `make icon SOURCE=...` | Generate AppIcon.icns |

---

## Resources

- [App Store Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- [Human Interface Guidelines - macOS](https://developer.apple.com/design/human-interface-guidelines/macos)
- [App Sandbox Design Guide](https://developer.apple.com/library/archive/documentation/Security/Conceptual/AppSandboxDesignGuide/)
- [Notarizing macOS Software](https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution)
