# Screen Context Reuse for Incremental Transcription

## Status

Implemented in PR (automation): `currentSnapshot()` session reads; snapshot cleared at recording boundaries only.

## Summary

Incremental transcription can split one recording into multiple pause-separated chunks. Previously,
`TranscriptionSteeringContext.make()` called `consumeSnapshot()`, so only the first chunk in a
recording session received screen-derived terms.

## Evidence (pre-fix)

- `ScreenContextStore.consumeSnapshot()` read the stored snapshot and immediately cleared it.
- `TranscriptionSteeringContext.make()` called `consumeSnapshot()` every time a chunk was sent to
  the selected transcription engine.
- `AppDelegate` wires `IncrementalTranscriptionCoordinator` so every sealed chunk calls
  `transcribeWithSelectedEngine(audioBuffer:)`.

Relevant files:

- `Sources/Voicey/Transcription/ScreenContextStore.swift`
- `Sources/Voicey/Transcription/TranscriptionSteeringContext.swift`
- `Sources/Voicey/Transcription/IncrementalTranscriptionCoordinator.swift`
- `Sources/Voicey/App/AppDelegate.swift`

## Fix

- **`currentSnapshot()`** — read without clearing; used by steering context for every chunk.
- **`clear()`** — already called at record start in `startScreenContextCaptureIfNeeded()`; remains
  the session boundary.

## Acceptance criteria

- [x] All chunks in one recording session can use the same screen-context snapshot.
- [x] Manual glossary terms continue to reflect current settings (unchanged policy).
- [x] The screen snapshot is cleared only at recording/session boundaries.
- [x] Tests prove two steering builds with the same snapshot both receive screen terms.
- [x] `currentSnapshot()` regression test — store is not cleared by read.

## Validation plan

- [x] Linux: `SteeringContextSessionReuseTests` (VoiceyCore).
- [x] macOS: `ScreenContextStoreTests` (VoiceyTests).
- [ ] macOS manual: dictate a term from the active window before and after a pause; steering applies
  consistently (macOS sign-off: [`MACOS_MANUAL_QA.md`](../MACOS_MANUAL_QA.md), [#145](https://github.com/jonathanKingston/voicey/issues/145)).
