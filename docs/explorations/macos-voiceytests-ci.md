# macOS VoiceyTests CI

## Status

Implemented in CI — see `.github/workflows/build.yml` (`swift test --filter VoiceyTests`).

## Summary

The macOS CI workflow runs only a hand-curated subset of the `VoiceyTests` target, not the whole
target. Linux CI cannot compile app targets that import Apple frameworks, so macOS CI is the only
place app-layer tests can protect recording, runtime, overlay, and clipboard behavior. Because the
subset is a manually maintained `--filter` allowlist, app-layer test classes that are not listed
run nowhere in CI and can silently rot.

## Evidence

- `.github/workflows/build.yml` runs `make build` on `macos-15`, then a `macOS unit tests` step:
  `swift test --filter 'AudioWaveformEnvelopeTests|HandsFreeFlushBarrierTests|IncrementalTranscriptionCoordinatorTests|UtteranceTranscriptionFinishTests|MultiprocessRuntimeTests'`.
- That filter covers 5 of the 9 `VoiceyTests` classes. Not run in CI:
  `ClipboardManagerTests`, `ScreenContextStoreTests`, `TranscriptionOverlayControllerTests`,
  `VoiceySingleInstanceTests`.
- The filter is an allowlist that has grown PR-by-PR as specific regressions were fixed (e.g.
  `UtteranceTranscriptionFinishTests` added in #159); there is no technical reason behind the
  exclusions. Running the full target locally (`swift test --filter VoiceyTests`) passes all 45
  tests headlessly, including all four currently-unlisted classes.
- `Package.swift` defines a `VoiceyTests` test target that depends on `Voicey`.
- `Tests/VoiceyTests` includes app-layer tests for multiprocess runtime, incremental
  transcription, clipboard restore, overlay state, single-instance locking, and waveform behavior.
- `Tests/VoiceyCoreTests` covers only the framework target that is Linux-testable.

Relevant files:

- `.github/workflows/build.yml`
- `Package.swift`
- `Tests/VoiceyTests`
- `Tests/VoiceyCoreTests`

## Risks

- App-layer regressions in unlisted classes can pass CI as long as the app compiles.
- New app-layer test classes are not enforced unless someone remembers to extend the `--filter`
  allowlist; the four unlisted classes already demonstrate this drift.
- macOS-specific runtime and UI-adjacent behavior has weaker review feedback.
- Future refactors may avoid adding tests because CI does not enforce them by default.

## Proposed direction

Run the whole `VoiceyTests` target in CI instead of a hand-maintained allowlist, keeping build and
test failures visible separately. All 45 tests already pass headlessly on a macOS runner, so the
default should be to run the full target and only carve out specific cases (with a documented
reason) if they later prove flaky or require permissions/UI automation.

Possible implementation shape:

1. Replace the `--filter` allowlist with `swift test --filter VoiceyTests` (the whole target) after
   `make build`.
2. Add any required Rust worker setup before tests if app tests depend on worker binaries.
3. Keep Linux `VoiceyCoreTests` separate.
4. Document tests that must remain manual due to permissions or UI automation.
5. Consider uploading test logs as artifacts on failure.

## Acceptance criteria

- macOS CI runs the app-layer `VoiceyTests` target.
- Failures block pull requests.
- Required worker or MLX setup is documented in the workflow.
- Tests that cannot run in CI are explicitly marked and explained.
- New app-layer behavior has a clear place to add regression tests.

## Validation plan

- Run the new workflow on a PR and confirm `VoiceyTests` executes.
- Confirm a deliberately failing `VoiceyTests` test fails CI before reverting it.
- Keep Linux CI focused on `VoiceyCoreTests` and non-Apple checks.
