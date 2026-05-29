# Hands-Free recording mode

Spec for adding an opinionated hands-free recording mode to Voicey.

## Summary

Voicey should add a second recording mode named **Hands-Free**.

- `Manual` keeps the current behavior: press once to start recording, press again to stop.
- `Hands-Free` changes only the capture interaction: press once to arm recording, Voicey waits for speech, starts automatically when speech is detected, and stops after the user pauses.

This feature is meant to improve dictation ergonomics without changing Voicey's core product shape.

## Product goals

1. Improve dictation flow for users who do not want to press the hotkey twice.
2. Keep Voicey opinionated: one additional mode, no provider sprawl, no workflow builder.
3. Reuse the existing Voicey capture -> steer -> transcribe -> deliver pipeline.
4. Preserve parity between the Swift capture path and the default Rust capture worker path.

## Non-goals

The first version must not introduce any of the following:

- wake word / always-listening behavior
- live transcript streaming while speaking
- cloud-specific VAD implementations
- a large settings surface for sensitivity tuning
- Whispering-style transformation pipelines
- alternate user-facing model choices beyond Voicey's existing opinionated model surface

## Naming

### User-facing name

Use **Hands-Free** in product UI.

Do not use `VAD` in the UI. It is implementation jargon.

Do not use `Voice Activated` as the primary label. In Voicey, the user still initiates the interaction with the hotkey, so "voice activated" overstates what the feature does.

### User-facing description

Use this copy in settings and onboarding:

> Press the hotkey once. Voicey waits for you to speak, starts automatically, and transcribes after you pause.

### Internal terminology

Use `VAD` or `speech detection` in code and docs when talking about the implementation.

## UX

## Recording modes

Voicey should expose exactly two recording modes in v1:

- `Manual`
- `Hands-Free`

The mode selector belongs in `Settings -> Audio`.

## Manual mode

No behavioral changes.

1. User presses hotkey.
2. Voicey starts recording immediately.
3. User presses hotkey again to stop.
4. Voicey transcribes and delivers text.

## Hands-Free mode

1. User presses hotkey once.
2. Voicey validates model readiness exactly as it does today.
3. Voicey captures the target app / target screen exactly as it does today.
4. Voicey starts screen-context capture exactly as it does today.
5. Voicey pauses media exactly as it does today.
6. Voicey shows the overlay with a new "waiting for speech" state.
7. Voicey arms microphone capture and buffers pre-roll audio.
8. When speech is detected, Voicey transitions into active recording automatically.
9. When the user pauses long enough, Voicey stops capture automatically.
10. Voicey runs the existing transcription, post-processing, and output-delivery path.

## Hotkey semantics

### Manual mode

Unchanged:

- hotkey while idle -> start recording
- hotkey while recording -> stop recording

### Hands-Free mode

- hotkey while idle -> arm and wait for speech
- hotkey while waiting for speech -> cancel
- hotkey while actively recording -> force stop immediately

## Escape semantics

Escape should cancel both of these states:

- waiting for speech
- actively recording

This keeps behavior consistent with the current overlay cancel model.

## Overlay copy

Use these labels:

- `Ready`
- `Waiting for speech`
- `Listening`
- `Transcribing`
- existing completed / error labels remain unchanged

Notes:

- `Waiting for speech` is shown only for Hands-Free mode after arming and before speech start.
- `Listening` remains the active recording label after speech start.

## Architecture

Hands-Free mode is a recording-mode extension of the existing Voicey runtime, not a second transcription pipeline.

The existing flow must remain the source of truth:

1. preflight and model readiness
2. target app / target screen capture
3. screen-context capture
4. media pause
5. microphone capture
6. transcription steering
7. transcription
8. output delivery

Hands-Free only changes how capture starts and stops.

## State model

## `TranscriptionState`

Extend `TranscriptionState` with a new case:

- `waitingForSpeech(startTime: Date)`

Rationale:

- "armed and silent" is a real user-visible state
- active recording should still mean real speech capture is underway
- duration limiting should not start at the arm time

### Expected state transitions

#### Manual

`idle -> loadingModel? -> recording -> processing -> completed/error -> idle`

#### Hands-Free

`idle -> loadingModel? -> waitingForSpeech -> recording -> processing -> completed/error -> idle`

### Expected convenience properties

Update convenience helpers so they behave correctly:

- `isActive` should include `waitingForSpeech`
- `isRecording` should continue to mean "actual speech capture is running"
- add a new helper such as `isWaitingForSpeech` if useful

## Settings model

Add a new recording mode setting with exactly two values:

- `manual`
- `handsFree`

Recommended shape:

- `enum RecordingMode: String, CaseIterable, Sendable`
- store the raw value in `SettingsManager`

Recommended default:

- `manual`

## File-level implementation targets

The exact file layout can change, but the spec assumes the following areas will be touched.

### State / settings

- `Sources/Voicey/App/AppState.swift`
- `Sources/Voicey/Utilities/Settings.swift`
- `Sources/Voicey/Utilities/Localization.swift`

### App orchestration

- `Sources/Voicey/App/AppDelegate.swift`
- `Sources/Voicey/App/AppDelegate+AudioCaptureManagerDelegate.swift`

### Audio detection

- `Sources/Voicey/Audio/AudioCaptureManager.swift`
- optionally add a new file for detection configuration / helper types under `Sources/Voicey/Audio/`

### UI

- `Sources/Voicey/UI/SettingsView.swift`
- `Sources/Voicey/UI/TranscriptionOverlay.swift`

### Rust capture parity

- `Sources/Voicey/Runtime/VoiceyCaptureWorkerSession.swift`
- Rust `voicey-capture` worker protocol and implementation
- `docs/RUST_RUNTIME.md`

## Detection design

## Implementation approach

Use a native energy-based speech detector built on Voicey's existing audio path.

Do not add a new cross-platform VAD dependency for v1.

Voicey already has:

- 16 kHz mono capture
- rolling input level updates
- RMS calculation
- trailing low-energy trimming

That is enough to build a first hands-free mode without introducing a second audio stack.

## Detection behavior

The detector should use:

- rolling RMS / level analysis
- pre-roll buffering
- hysteresis
- minimum speech duration
- silence hangover before stop

## Required detector configuration

Keep all v1 thresholds internal to the app.

Do not expose user-facing knobs in v1.

Recommended internal configuration values:

- `preRollDuration`
- `speechStartThreshold`
- `speechEndThreshold`
- `minimumSpeechDuration`
- `silenceHangoverDuration`
- `maximumWaitForSpeechDuration`

These should be centralized in one place rather than embedded as scattered magic numbers.

## Pre-roll requirement

Hands-Free mode must preserve a short ring buffer before speech start so the beginning of the first word is not clipped.

When speech begins:

- prepend the pre-roll buffer
- then continue appending live capture

## Stop condition

Hands-Free mode should stop when silence has persisted for the configured hangover duration.

This stop condition should end active recording only after speech has actually started.

The detector must not auto-stop just because the user is silent before first speech.

## Wait timeout

Hands-Free mode should not stay armed forever.

If no speech is detected within the configured wait timeout:

- cancel capture
- hide the overlay
- restore any paused media
- return to `idle`

Do not produce an error toast for a quiet timeout in v1. Treat it as a clean cancel.

## Delegate contract

Extend `AudioCaptureManagerDelegate` beyond level updates.

Recommended callbacks:

- `didEnterWaitingForSpeech`
- `didDetectSpeechStart`
- `didDetectSpeechEnd`

Exact naming can vary, but the split of responsibilities should stay the same:

- `AudioCaptureManager` owns speech detection
- `AppDelegate` owns app state, overlay behavior, and transcription orchestration

## `AudioCaptureManager` behavior

## New capture modes

Add a capture mode concept to the audio layer. Recommended shape:

- `manual`
- `handsFree`

`startCapture(...)` should accept the desired mode rather than relying on a separate side channel.

## Swift capture path

In the AVAudioEngine path:

1. start the engine as today
2. when in Hands-Free mode, keep a rolling pre-roll buffer before speech start
3. emit delegate state changes when speech starts / ends
4. append only the speech-bounded clip plus pre-roll to the final transcription buffer

## Rust capture worker path

Hands-Free mode must also work when `voicey-capture` is enabled.

Do not ship a version where Hands-Free is available only on the AVAudioEngine path. Voicey defaults to the worker hot path when bundled, so split behavior would create inconsistent product behavior.

### Worker protocol requirement

Extend the capture worker protocol so the mode is explicit.

Recommended request shape:

- `start_recording` accepts `mode: "manual" | "hands_free"`

Recommended worker outcomes:

- it either emits status transitions that the host can observe
- or it returns exact speech-bounded samples / speech boundaries on stop

The exact transport is flexible, but parity is required:

- same observable user behavior
- same minimum clip handling
- same armed timeout behavior
- same silence hangover behavior

## `AppDelegate` integration

## Reuse the current start path

`startRecording()` should keep all current preflight logic:

- model availability
- model preload
- fallback to downloaded user-facing Qwen model
- target app capture
- target screen capture
- screen-context capture
- media pause
- overlay presentation

The only difference is what happens after audio capture is started.

## New recording control flow

### Manual mode

Current behavior remains unchanged.

### Hands-Free mode

After preflight:

1. set `transcriptionState` to `waitingForSpeech`
2. show overlay
3. start audio capture in hands-free mode
4. wait for delegate callback for speech start
5. when speech starts, transition to `.recording(startTime:)`
6. when speech ends, call the existing stop/transcribe path with the final bounded audio

## Forced stop

If the user presses the hotkey while actively recording in Hands-Free mode:

- stop immediately
- transcribe what has been captured so far

If the user presses the hotkey while still waiting for speech:

- cancel cleanly
- do not transcribe

## Duration limiting

Current max recording duration should continue to exist, but the timer semantics change in Hands-Free mode.

### Rule

The max duration starts when speech begins, not when the app enters `waitingForSpeech`.

### Minimum duration

Minimum clip duration should be measured against the final speech-bounded clip, not against total armed time.

## Media pause / resume

Keep the existing media behavior:

- pause when the session arms
- resume when capture ends

This preserves the current "recording only" semantics for media pause while avoiding a second policy branch.

## Output delivery

Hands-Free mode should reuse the existing output path exactly:

- post-processing
- clipboard copy
- auto-paste
- clipboard restore
- terminal-aware paste behavior

No output settings changes are required for v1.

## Settings UI

Add a new `Recording` section to `Settings -> Audio`.

Recommended UI:

- segmented control or picker with:
  - `Manual`
  - `Hands-Free`

Recommended descriptions:

- `Manual` — Press once to start, press again to stop.
- `Hands-Free` — Press once. Voicey starts when you speak and transcribes after you pause.

Do not add sensitivity sliders in v1.

## Overlay UI

The existing overlay should be extended, not replaced.

Requirements:

- a distinct `Waiting for speech` label
- existing cancel affordance still works
- no large new controls
- no always-listening visual treatment

The overlay should continue to feel like a temporary recording HUD, not a persistent assistant surface.

## Logging

Add structured logs for:

- recording mode chosen
- arm start
- speech start
- speech end
- quiet timeout
- forced stop
- final bounded clip duration

Do not log raw transcript steering terms or other sensitive content beyond current behavior.

## Accessibility and permissions

Hands-Free mode should not change permissions behavior.

It still depends on:

- microphone permission
- accessibility permission only when existing auto-paste / screen-context features require it
- screen recording permission only when OCR fallback is already enabled

## Failure policy

Hands-Free mode should fail predictably.

### Required policy

- If the worker/runtime cannot support Hands-Free yet, do not silently ship a degraded variant on one capture path only.
- If a capture session cannot arm, surface the same class of error Voicey already uses for capture failures.
- If the user never speaks, cancel cleanly after timeout.

This project should prefer parity and explicit failure over hidden fallback behavior.

## Acceptance criteria

## Product acceptance

1. Voicey exposes exactly two recording modes: `Manual` and `Hands-Free`.
2. `Hands-Free` uses the copy: "Press the hotkey once. Voicey waits for you to speak, starts automatically, and transcribes after you pause."
3. Manual mode remains behaviorally unchanged.
4. Hands-Free mode does not add any new user-facing model selection.
5. No new sensitivity controls are present in settings in v1.

## Runtime acceptance

1. Pressing the hotkey in Hands-Free mode arms capture and shows `Waiting for speech`.
2. Beginning to speak transitions the overlay to `Listening`.
3. Pausing for long enough stops capture automatically and starts transcription.
4. Pressing the hotkey while waiting cancels without transcription.
5. Pressing Escape while waiting cancels without transcription.
6. Pressing the hotkey while actively recording force-stops and transcribes the captured speech.
7. Maximum recording duration starts at speech start, not arm time.
8. Minimum clip duration is evaluated on the final speech-bounded clip.
9. Existing steering, post-processing, and output delivery behavior still run after Hands-Free capture.
10. Behavior is materially the same on both:
    - AVAudioEngine capture path
    - `voicey-capture` worker path

## Validation plan

The feature must be manually validated on macOS.

Minimum manual validation matrix:

- Manual mode regression
- Hands-Free in a quiet room
- Hands-Free with moderate background noise
- immediate speech after hotkey press
- delayed speech after hotkey press
- short false start / cough / keyboard clack
- brief mid-sentence pause that should not end capture
- final long pause that should end capture
- Escape while waiting
- hotkey press while waiting
- hotkey press while recording
- auto-paste into a standard text field
- auto-paste into a terminal target
- media pause/resume during Hands-Free capture
- worker path parity vs Swift path parity

## Suggested implementation slices

### Slice 1: state + settings

- add `RecordingMode`
- add `waitingForSpeech`
- add localization
- add settings UI

### Slice 2: Swift audio path

- add speech detection configuration
- add pre-roll ring buffer
- emit delegate callbacks
- produce speech-bounded clips

### Slice 3: app orchestration

- wire Hands-Free mode into `AppDelegate`
- preserve existing model / context / media / output flow
- update overlay states

### Slice 4: Rust worker parity

- extend JSONL protocol
- add Hands-Free support to `voicey-capture`
- update docs / diagnostics as needed

### Slice 5: tuning + QA

- tune thresholds on real dictation scenarios
- verify no regressions in Manual mode
- verify parity across capture backends

## Explicit defer list

The following ideas are intentionally deferred out of this spec:

- wake-word activation
- user-tunable sensitivity controls
- long-form meeting mode
- live transcript view
- multi-stage rewrite or transformation pipelines
- clipboard transformation windows
- provider-specific speech detection logic

