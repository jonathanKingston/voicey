# Screen Context Capture Determinism

## Status

Exploration merged ([#109](https://github.com/jonathanKingston/voicey/pull/109)). Implementation in
open PR [#150](https://github.com/jonathanKingston/voicey/pull/150) (`ScreenContextCaptureGate`), pending macOS QA sign-off.
macOS manual validation: [`MACOS_MANUAL_QA.md`](../MACOS_MANUAL_QA.md) § PR #150 ([#145](https://github.com/jonathanKingston/voicey/issues/145) closed; checklist retained).

## Summary

Screen-context steering is enabled by default, but the capture pipeline runs in a detached task
and transcription consumes whatever snapshot happens to be ready. Short recordings can finish
before accessibility or OCR capture completes, causing steering to silently run without screen
terms.

## Evidence

- `AppDelegate.startScreenContextCaptureIfNeeded()` clears the store, checks permissions, and
  starts `Task.detached(priority: .utility)`.
- The detached task collects Accessibility context, optionally performs OCR, and writes the
  snapshot to `ScreenContextStore`.
- `AppDelegate.transcribeWithSelectedEngine(audioBuffer:)` calls
  `TranscriptionSteeringContext.make()` at transcription time.
- `TranscriptionSteeringContext.make()` consumes from `ScreenContextStore` synchronously and
  logs only whether terms were found, not whether capture was still in flight.

Relevant files:

- `Sources/Voicey/App/AppDelegate.swift`
- `Sources/Voicey/Accessibility/ScreenContextCollector.swift`
- `Sources/Voicey/Accessibility/ScreenContextOCR.swift`
- `Sources/Voicey/Transcription/TranscriptionSteeringContext.swift`
- `Sources/Voicey/Transcription/ScreenContextStore.swift`

## Risks

- The feature can appear enabled while frequently contributing no terms.
- OCR paths increase timing variance, making behavior harder to reason about.
- Logs do not distinguish "no terms exist" from "capture missed the transcription deadline."
- Users may tune glossary or screen-context settings without seeing consistent effects.

## Proposed direction

Make screen-context capture a per-recording operation with an explicit completion handle.
Transcription should await that handle up to a short timeout before building decoder context.

Possible implementation shape:

1. Replace fire-and-forget storage with a `ScreenContextCaptureSession`.
2. Store the session on the recording lifecycle object.
3. Await capture before transcription with a bounded timeout.
4. Log one of: `ready`, `timeout`, `disabled`, `permissionDenied`, or `empty`.
5. Keep OCR optional but make its timeout budget visible.

## Acceptance criteria

- When screen context is enabled, transcription waits for capture or times out explicitly.
- Logs/metrics show whether screen context was ready, empty, or missed by timeout.
- Short recordings no longer race against a detached capture task without observability.
- OCR-enabled capture has a bounded timeout and does not block indefinitely.
- Tests cover fast recording completion and slow OCR completion.

## Validation plan

- Add unit coverage for a fake capture session that completes before and after timeout.
- Add an integration-level test around context construction with delayed screen context.
- On macOS, manually verify a short recording logs a deterministic screen-context outcome.
