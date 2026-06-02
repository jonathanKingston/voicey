# Async Audio Capture API

## Status

Exploratory proposal.

## Summary

The Rust capture hot path bridges async worker calls back into synchronous methods with a
blocking semaphore. This makes capture start/stop easy for existing callers, but it risks UI
stalls and priority inversions when those methods run on main-thread or callback-sensitive paths.

## Evidence

- `AudioCaptureManager.startCapture(mode:)` calls `runSynchronously` before returning when the
  Rust capture worker is enabled.
- `AudioCaptureManager.stopCapture()` and related Rust paths also need worker operations to
  complete before continuing.
- `runSynchronously` creates an unstructured `Task`, stores a result, then blocks the current
  thread with `DispatchSemaphore.wait()`.

Relevant files:

- `Sources/Voicey/Audio/AudioCaptureManager.swift`
- `Sources/Voicey/App/AppDelegate.swift`
- `Sources/Voicey/Runtime/VoiceyCaptureWorkerSession.swift`
- `Sources/Voicey/Runtime/VoiceyRuntimeConfiguration.swift`

## Risks

- Main-thread callers can block the app while worker startup or stop is slow.
- Blocking a cooperative executor path can make cancellation and shutdown less predictable.
- Race conditions are harder to test because synchronous API shape hides async boundaries.
- Hands-free flows increase exposure because capture operations repeat frequently.

## Proposed direction

Move capture operations to async APIs and let call sites decide how to sequence UI state updates.
The synchronous AVAudioEngine path can remain internally synchronous, but the public capture
interface should not block on async worker operations.

Possible implementation shape:

1. Introduce `startCapture(mode:) async throws`.
2. Introduce `stopCapture() async -> CapturedAudio?` or a typed result.
3. Keep level callbacks and delegate methods main-actor safe.
4. Update `AppDelegate` recording flows to await capture operations from explicit tasks.
5. Remove `runSynchronously`.

## Acceptance criteria

- No `DispatchSemaphore.wait()` is used to bridge capture worker calls.
- Starting, stopping, and finalizing capture can be awaited.
- Errors from worker startup reach `AppDelegate` as typed failures.
- Rapid start/stop and hands-free utterance loops do not hang.
- Tests cover slow worker startup and worker stop failure.

## Validation plan

- Add tests around a fake capture worker session with delayed start/stop.
- On macOS, run Rust capture mode and rapidly toggle recording.
- On macOS, verify hands-free mode can detect, transcribe, and resume listening without UI stalls.
