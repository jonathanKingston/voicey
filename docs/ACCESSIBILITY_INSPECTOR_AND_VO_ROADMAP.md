# Voicey: Accessibility Inspector & VoiceOver roadmap

This document lists concrete improvements so Voicey **practices strong in-app accessibility** (VoiceOver, keyboard navigation, Inspectable hierarchy) distinct from controversial **cross-app Accessibility API** usage (insertion elsewhere). Implementation notes point at current code where relevant.

Verification workflow:

1. **Accessibility Inspector**: Audit `Settings`, `Transcription Overlay`, menus; enable “Highlight issues”.
2. **VoiceOver**: `⌘ F5`, navigate each surface with VO + arrows, Tab, and rotor.
3. **Keyboard**: Navigate Settings window without pointing device (`Ctrl F7` Full Keyboard Access if needed).

---

## 1. Issues visible from the current codebase

### 1.1 Transcription overlay (`TranscriptionOverlayView`, `TranscriptionOverlayController`)

| Issue | Detail | Direction |
|--------|--------|-----------|
| **Grouped content hidden** | `stateIcon` uses `.accessibilityElement(children: .ignore)` with **no compensating combined label**. VoiceOver may barely describe what is happening during recording vs processing. | Use a single **combined** AX element for the HUD: `accessibilityElement(children: .combine)` **or** a dedicated `accessibilityLabel`/`accessibilityValue` reflecting `TranscriptionState` (recording / processing / loading + optional duration). |
| **Decorative waveform** | `WaveformView` is purely visual feedback. VO users need **equivalent status** (“Recording, audio level…” is hard; minimum is clear **state + duration text** elsewhere or `accessibilityLabel` updates). | Prefer exposing **explicit text** (e.g. “Recording 0:42”) VO can read periodically, or concise value updates sparingly (avoid chatter). |
| **Close button** | Icon-only `.buttonStyle(.plain)` with `.focusEffectDisabled()`. Weak keyboard/VO affordance (`help` alone is insufficient for VO). | Add `.accessibilityLabel` (localized) aligned with `L10n.Overlay.cancelHelp`, consider **keyboard focus ring** unless there is an intentional design exemption; revisit `focusEffectDisabled`. |
| **Floating `KeyablePanel`** | `.nonactivatingPanel`, custom key handling — often **skipped or confusing** with VO ordering. | On `NSHostingView` / panel: verify `accessibilityRole` / `subrole` (“floating panel”), **title**, and **`setAccessibilityIgnored(false)`** where needed so HUD appears when shown. Optionally post `NSAccessibilityPriorityKey`/`LayoutChanged` when overlay appears (`NSAccessibility.raise`) so VO notices. |
| **Reduce transparency** | `accessibilityReduceTransparency` already gates glass → solid fill (**good**). | Extend **Reduce Motion** (`accessibilityReduceMotion`) to waveform / pulsing visuals if animations are perceptible. |

### 1.2 Hotkey recorder (`KeybindingRecorderView`)

| Issue | Detail | Direction |
|--------|--------|-----------|
| **Plain recorder button** | Presents live **shortcut string** visually but VO may announce only generic “button” semantics. | `accessibilityLabel`: “Record transcription shortcut”. `accessibilityValue`: **current chord** (`shortcut.description`). `accessibilityHint`: “Starts listening for a key combination; Escape cancels recording.” While `isRecording == true`, use `accessibilityAddTraits(.startsMediaSession)` sparingly — better: **custom trait** hint “Listening for shortcut”. |
| **Clear shortcut** (`xmark.circle`) | Decorative icon button. | Dedicated `accessibilityLabel` (“Clear shortcut”) / `Hint`. |

### 1.3 Settings sidebar (`NavigationSplitView` / `SettingsSidebarRow`)

| Issue | Detail | Direction |
|--------|--------|-----------|
| Selection state | Rows use styling for selection; confirm VO reads **selected** vs unselected consistently (`List(selection:)` should help — verify rotor “layout” order). | If issues persist, add `.accessibilityIdentifier` per tab for UI tests — also helps Inspectable auditing. |

### 1.4 Voice Commands rows (`VoiceCommandRow`)

| Issue | Detail | Direction |
|--------|--------|-----------|
| Toggle with **hidden label** | `Toggle("", …).labelsHidden()` — VO users hear unlabeled switches. | Pair with `.accessibilityLabel` built from **phrase + action** (e.g. “Enable command: new line when you say ‘period’”). |

### 1.5 Menubar extra (`StatusBarController`)

| Issue | Detail | Direction |
|--------|--------|-----------|
| Tooltip vs VO | SF Symbol sets `accessibilityDescription: "Voicey"` — **good start**, but VO should hear **dynamic state**: idle / recording / model loading/failed if possible. | Update status item accessibility **when** recording or model changes (mirroring `updateTooltip` / icon animation). Prefer string parity with localized tooltips. |

### 1.6 General SwiftUI/AppKit hygiene

| Area | Action |
|------|--------|
| **Dynamic type** | Audit fixed font sizes in overlay (`14`, `system size 12`) — expose **preferred content size support** (`@ScaledMetric` / `DynamicTypeSize`) for partial vision. |
| **Window titles** | Settings window title should include “Voicey” + context for multitasking/VO (“Voicey Settings”). |
| **Full Keyboard Access + focus order** | Every actionable control reachable in logical order tab cycle; overlays should not steal focus unexpectedly without announcement. |

---

## 2. Other **functional** product changes that improve accessibility

These go beyond Inspectable audits; they mirror **motor**, **cognitive**, and **speech-primary input** scenarios.

### 2.1 Input modalities (beyond “better labels”)

| Change | Audience | Effort vs impact |
|--------|----------|------------------|
| **Push-to-talk (hold)** | Users who confuse **toggle** endpoints or fatigue from double-triggering chords. | Add optional **hold chord = record, release = stop + transcribe** alongside existing toggle — common assistive paradigm. |
| **Longer dwell / confirmation** before starting | Accidental firing of global shortcuts. | Optional “warm start”: first chord arms, second confirms; or configurable **delay** — reduces errors for tremor/low precision. |
| **On-screen record control** | Users who **cannot** hit global shortcuts reliably. | Prominent **Start / Stop** in Settings or a **small always-available floater** (optional) — still must not require pointer if keyboard path exists. |
| **System Dictation / Voice Control compatibility note** | Users already on Apple’s voice stack. | Document interaction (no double-capture, mic conflicts) in Help; optionally detect `UIElementIsVoiceOverRunning` / reduce competing global chords (see below). |

### 2.2 Output & feedback

| Clear **success/failure** speech or sound | Low-vision users may miss menubar-only feedback. | Optional **short success tone** + **UserNotifications** for errors (already partially used) with consistent copy. |
| **Longer display of errors** in overlay | Cognitive load: transient errors vanish. | Persist error state with explicit “Dismiss” for NV/VO. |

### 2.3 Language & cognitive

| Simpler **Setup** path | Single linear checklist with **Next** (already partially there in `SetupSettingsView` — extend). | Reduces decision fatigue. |

---

## 3. Should we change the default trigger key?

**Context today:** Default is **⌃ V** (see `Localizable.strings` / reset copy). Global shortcut comes from **KeyboardShortcuts** (`AppDelegate.setupHotkey`).

| Consideration | Guidance |
|----------------|----------|
| **VoiceOver** | VoiceOver uses **⌃ ⌥** heavily. **⌃ by itself** is often less conflicted than **⌃ ⌥** chords, but **any** global shortcut can clash with user-defined VO commands or other AT. |
| **Motor** | Short **two-key** chords (modifier + letter) are common; **triple** or **double-tap** keys are harder. |
| **Discoverability** | Changing default upsets existing users — prefer **presets** in Hotkey settings: “Default”, “VoiceOver-friendly (suggested)”, “Custom”. |

**Recommendation:** Do **not** silently change the default for everyone. **Add documented presets** and in-app note: *“If you use VoiceOver, pick a shortcut that doesn’t conflict with your VO commanders.”* Optionally detect VoiceOver at runtime and **suggest** (not force) an alternate.

---

## 4. “Always recording” + paste with a **wake word**?

| Pros | Cons |
|------|------|
| Removes **need to press keys** — strong for **severe motor** limitation. | **Battery**, **CPU**, **privacy perception**, **false triggers**, **background mic** policy and App Store scrutiny; requires **VAD** + on-device keyword or OS API. |
| Aligns with “speech is my only input” narrative. | Hard to ship as **fully local** without quality tradeoffs; always-on mic is a **major** policy and UX commitment. |

**Recommendation:** Treat as a **large** feature (opt-in, clear consent, visible recording state, easy kill switch). It can **strengthen** real assistive positioning **if** implemented carefully, but it does **not** fix guideline **2.4.5** by itself (Apple may still classify cross-app AX insertion as non-accessibility).

---

## 5. Media keys or similar hardware triggers?

| Idea | Notes |
|------|--------|
| **Media keys** (play/pause, etc.) | On many Mac keyboards these are **ambiguous** (Music, inconsistent capture), require **event tap** / **CGEvent** listen — similar permission story to global hotkeys. Not all hardware exposes spare media keys. |
| **Headset button** | Same class of global event problems; limited API surface. |
| **MIDI / Switch interfaces** | Genuine assistive path for switch users but niche integration cost. |

**Recommendation:** **Lower priority** than **push-to-talk**, **UI buttons**, and **better shortcut conflict handling**. If pursued, treat as **optional advanced** binding through the same **KeyboardShortcuts** / tap infrastructure with explicit risk documentation.

---

## 6. Summary priorities (suggested order)

1. **Overlay + panel**: combined accessibility element, dynamic label/value, VO notification on show, close button labels, reduce-motion pass.  
2. **KeybindingRecorderView**: label / value / hint / clear button.  
3. **Voice command toggles**: visible accessibility labels.  
4. **Status item**: dynamic accessibility description = state.  
5. **Product**: push-to-talk option; shortcut conflict presets; optional on-screen controls.  
6. **Larger bet**: wake-word always-listening only with full privacy/engineering plan.

---

## 7. Out of scope for this doc (but related)

- **Guideline 2.4.5** (Accessibility API for typing into *other* apps): improving **in-app** VoiceOver does **not** automatically legitimize cross-app AX. Plan **clipboard-only** or **direct-distribution** paths separately.
