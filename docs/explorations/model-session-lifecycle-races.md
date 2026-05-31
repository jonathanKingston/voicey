# Model Session Lifecycle Races

## Status

Partially implemented (PR follows #108). Remaining: capture a stable `SpeechModel` per transcription session instead of re-reading settings mid-flight.

## Summary

Model upgrades and user-selected model changes can mutate the active model while a recording
or transcription session is running. The current flow has separate guards for some upgrade
paths, but no single session coordinator owns the invariant that the selected model, app state,
and loaded inference engine remain stable for an active transcription.

## Evidence

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

## Proposed direction

Introduce one model/session lifecycle gate owned on the main actor. It should make model swaps
and recording starts mutually exclusive, and it should capture the model used by a transcription
session at session start.

Possible implementation shape:

1. Add a small `RecordingSessionCoordinator` or `ModelLifecycleCoordinator`.
2. Represent active model transitions explicitly, for example `.ready(model)`,
   `.switching(from:to:)`, and `.failed(model,message)`.
3. Reject or queue model changes while `TranscriptionState.isActive` or hands-free mode is
   active.
4. Capture a per-session `SpeechModel` and pass it through transcription instead of repeatedly
   reading `SettingsManager.shared.selectedModel`.

## Acceptance criteria

- Recording cannot start while a model upgrade or model switch is in progress.
- Model changes from Settings are blocked or deferred during recording, processing, or active
  hands-free sessions.
- Active capture is never left with `appState.transcriptionState == .idle`.
- A transcription session uses one stable `SpeechModel` from start to finish.
- Regression coverage exercises model change during recording and pending upgrade during
  `startRecording()`.

## Validation plan

- Add focused tests around the lifecycle gate with mocked model loading.
- On macOS, manually verify: start recording, trigger a model change, and confirm the user gets
  clear feedback instead of a silent reset.
- On macOS, manually verify a pending upgrade cannot overlap rapid hotkey start/stop sequences.
