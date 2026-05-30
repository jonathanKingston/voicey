# Screen Context Reuse for Incremental Transcription

## Status

Exploratory proposal.

## Summary

Incremental transcription can split one recording into multiple pause-separated chunks. The
screen-context snapshot is consumed when decoder context is built, so only the first chunk in a
recording session can receive screen-derived terms.

## Evidence

- `ScreenContextStore.consumeScreenTerms(...)` reads the stored snapshot and immediately clears
  it.
- `TranscriptionSteeringContext.make()` calls `consumeScreenTerms(...)` every time a chunk is
  sent to the selected transcription engine.
- `AppDelegate` wires `IncrementalTranscriptionCoordinator` so every sealed chunk calls
  `transcribeWithSelectedEngine(audioBuffer:)`.

Relevant files:

- `Sources/Voicey/Transcription/ScreenContextStore.swift`
- `Sources/Voicey/Transcription/TranscriptionSteeringContext.swift`
- `Sources/Voicey/Transcription/IncrementalTranscriptionCoordinator.swift`
- `Sources/Voicey/App/AppDelegate.swift`

## Risks

- Long dictations degrade after the first pause because screen terms disappear.
- Results depend on pause segmentation rather than user intent.
- The current API name makes this easy to miss because `consumeScreenTerms` couples ranking with
  lifecycle cleanup.

## Proposed direction

Separate snapshot lifetime from term selection. Screen context should be captured once per
recording session and reused for every chunk belonging to that session.

Possible implementation shape:

1. Introduce a per-session `TranscriptionSteeringSnapshot`.
2. Build the snapshot once after screen-context capture completes.
3. Pass the snapshot into each incremental chunk transcription.
4. Clear the snapshot when a new recording starts or the session is cancelled.
5. Rename APIs so consuming and selecting are not conflated.

## Acceptance criteria

- All chunks in one recording session can use the same screen-context snapshot.
- Manual glossary terms continue to reflect current settings according to an explicit policy.
- The screen snapshot is cleared only at recording/session boundaries.
- Tests prove two pause-separated chunks both receive screen terms.
- Cancellation and failed transcription clear the session snapshot.

## Validation plan

- Add a unit test for two incremental chunks with a preloaded screen-context snapshot.
- Add a regression test that verifies the store is not cleared by the first chunk.
- On macOS, manually dictate a term from the active window before and after a pause and confirm
  steering applies consistently.
