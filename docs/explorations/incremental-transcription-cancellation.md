# Incremental Transcription Cancellation

## Status

Implemented. This exploration drove the cancellation work that landed on `main` in
commit `f56ea29` (PR #148, tracking issue #147). The "Proposed direction" and "Acceptance
criteria" below are kept as the original design record; see the **Resolution** section for how
each was met. [#147](https://github.com/jonathanKingston/voicey/issues/147) is closed; a manual macOS Escape/cancel check remains in [`MACOS_MANUAL_QA.md`](../MACOS_MANUAL_QA.md) for merge sign-off.

## Resolution

- `reset()` now captures `processingTask` (and `publishSnapshotTask`) under the state lock,
  clears coordinator state, and cancels both tasks outside the lock; `cancel()` calls `reset()`.
- `processQueue(generation:)` already observes `Task.isCancelled`, so the cancelled task exits
  promptly and late transcribe results are discarded by the generation guard.
- Regression coverage lives in
  `Tests/VoiceyTests/IncrementalTranscriptionCoordinatorTests.swift`:
  `testCancelDuringActiveTranscriptionDiscardsInFlightWork` and
  `testCancelClearsQueuedChunksBehindInFlightTranscription`.
- Manual macOS check (checklist, not a blocking issue): pressing Escape during a long incremental
  partial returns the overlay to idle with no late partial text (see [`MACOS_MANUAL_QA.md`](../MACOS_MANUAL_QA.md)).

## Summary

`IncrementalTranscriptionCoordinator.cancel()` resets coordinator state but does not cancel the
task that may already be transcribing a sealed chunk. That can leave CPU, GPU, or worker work
running after the user cancels a recording.

## Evidence

- `cancel()` calls only `reset()`.
- `reset()` increments `generation`, clears buffers, clears pending chunks, and publishes an
  empty snapshot.
- `processingTask` is created by `startProcessingIfNeededLocked()`.
- `processQueue(generation:)` checks `Task.isCancelled`, but the task is never cancelled by the
  public cancel path.

Relevant files:

- `Sources/Voicey/Transcription/IncrementalTranscriptionCoordinator.swift`
- `Sources/Voicey/App/AppDelegate.swift`
- `Sources/Voicey/Runtime/VoiceyRuntimeSupervisor.swift`
- `Tests/VoiceyTests/IncrementalTranscriptionCoordinatorTests.swift`

## Risks

- Expensive transcription can continue after Escape/cancel.
- Late callbacks rely on generation checks to discard results, but still consume resources.
- Worker requests may remain active even after UI has returned to idle.
- Cancellation behavior differs from user expectation in hands-free and manual flows.

## Proposed direction

Make cancellation cooperative and explicit. The coordinator should cancel any active processing
task before clearing state, and downstream transcription APIs should observe cancellation where
possible.

Possible implementation shape:

1. Capture `processingTask` under the coordinator lock during cancel.
2. Call `cancel()` on the captured task outside the lock.
3. Ensure `flushAndFinish(...)` exits promptly when cancellation happens.
4. Propagate cancellation to worker clients where the protocol supports it, or discard and log
   late worker responses.
5. Add tests with a suspended fake transcriber to verify cancel behavior.

## Acceptance criteria

- `cancel()` cancels the in-flight processing task.
- No coordinator update is published after cancel except the expected empty reset snapshot.
- `flushAndFinish(...)` does not wait indefinitely after cancel.
- Tests cover cancel during active chunk transcription and cancel with pending chunks.
- Logs distinguish user cancellation from transcription failure.

## Validation plan

- Add unit tests using a fake transcribe closure that waits until cancellation.
- Verify the active task observes `Task.isCancelled`.
- On macOS, manually start a long transcription and cancel it, confirming the overlay returns to
  idle and no late result is delivered.
