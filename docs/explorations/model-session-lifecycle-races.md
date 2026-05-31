# Model Session Lifecycle Races

## Status

Implemented on `main`:

| PR | Delivers |
|----|----------|
| #140 | `ModelSessionLifecyclePolicy` gate — block recording during engine switch; defer settings-driven swaps while transcription is busy |
| #141 | Flush `deferredModelEngineSwitch` when `performModelUpgrade` finishes (not only on the next idle session) |
| #142 / #139 | `TranscriptionSessionModelPin` — stable `SpeechModel` per utterance |

Regression tests: `TranscriptionSessionBusySignalsTests`, `ModelSessionLifecyclePolicyTests`,
`TranscriptionSessionModelPinTests` (Linux / VoiceyCore).

## Summary

Model upgrades and user-selected model changes can mutate the active model while a recording
or transcription session is running. The current flow has separate guards for some upgrade
paths, but no single session coordinator owns the invariant that the selected model, app state,
and loaded inference engine remain stable for an active transcription.

## Historical evidence (pre-#140)

These behaviors motivated the gate; they are **not** current after #140–#142:

- `AppDelegate.tryPerformPendingUpgrade()` sets `isUpgradingModel` only after checking that
  `appState.transcriptionState == .idle`.
- `AppDelegate.performModelUpgrade(to:)` clears `isUpgradingModel` at the start of the
  background task, before the swap completes.
- `AppDelegate.startRecording()` does not check `isUpgradingModel`.
- `AppDelegate.handleSelectedModelChange(_:)` unconditionally updates `appState.currentModel`,
  unloads inactive engines, sets `appState.transcriptionState = .idle`, and preloads the new
  model.

Relevant files:

- `Sources/Voicey/App/AppDelegate.swift`
- `Sources/Voicey/App/AppState.swift`
- `Sources/Voicey/Transcription/ModelManager.swift`
- `Sources/Voicey/Runtime/VoiceyRuntimeSupervisor.swift`

## Risks

- Recording can begin while a background model upgrade is swapping engines.
- A settings model change can reset visible state to idle while capture or transcription still
  owns audio.
- `SettingsManager.shared.selectedModel`, `appState.currentModel`, and the loaded infer worker
  can disagree during an in-flight transcription.
- Failures are likely intermittent because they depend on model load timing and user input.

## Implementation (landed)

- `Sources/VoiceyCore/ModelSessionLifecyclePolicy.swift` + `ModelSessionLifecyclePolicy+AppState.swift`
- `Sources/VoiceyCore/TranscriptionSessionBusySignals.swift` — shared busy-session inputs for Linux tests
- `AppDelegate`: `isModelEngineSwitchInProgress`, `deferredModelEngineSwitch`, `onTranscriptionSessionIdleForModelLifecycle()`
- `Sources/VoiceyCore/TranscriptionSessionModelPin.swift` — pin at utterance start, clear on idle

## Acceptance criteria

- Recording cannot start while a model upgrade or model switch is in progress.
- Model changes from Settings are blocked or deferred during recording, processing, or active
  hands-free sessions.
- Active capture is never left with `appState.transcriptionState == .idle`.
- A transcription session uses one stable `SpeechModel` from start to finish.
- Regression coverage exercises model change during recording and pending upgrade during
  `startRecording()`.

## Validation plan

- [x] Linux `VoiceyCore` tests for busy-session signals (recording, hands-free session, flush) and
  model pin stability (`TranscriptionSessionBusySignalsTests`, `ModelSessionLifecyclePolicyTests`,
  `TranscriptionSessionModelPinTests`).
- [ ] On macOS, manually verify: start recording, trigger a model change, and confirm clear feedback instead of a silent reset.
- [ ] On macOS, manually verify a pending upgrade cannot overlap rapid hotkey start/stop sequences.
