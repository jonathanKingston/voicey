# macOS VoiceyTests CI

## Status

Exploratory proposal.

## Summary

The macOS CI workflow builds the app but does not run the existing `VoiceyTests` target. Linux CI
cannot compile app targets that import Apple frameworks, so macOS CI is the only place app-layer
tests can protect recording, runtime, overlay, and clipboard behavior.

## Evidence

- `.github/workflows/build.yml` runs `make build` on `macos-15`.
- `Package.swift` defines a `VoiceyTests` test target that depends on `Voicey`.
- `Tests/VoiceyTests` includes app-layer tests for multiprocess runtime, incremental
  transcription, clipboard restore, overlay state, and waveform behavior.
- `Tests/VoiceyCoreTests` covers only the framework target that is Linux-testable.

Relevant files:

- `.github/workflows/build.yml`
- `Package.swift`
- `Tests/VoiceyTests`
- `Tests/VoiceyCoreTests`

## Risks

- App-layer regressions can pass CI as long as the app compiles.
- Tests that already exist can silently rot.
- macOS-specific runtime and UI-adjacent behavior has weaker review feedback.
- Future refactors may avoid adding tests because CI does not enforce them.

## Proposed direction

Add a macOS CI test step for `VoiceyTests`, keeping build and test failures visible separately.
If some tests need special runtime setup, document that and split unsupported cases rather than
skipping the whole target.

Possible implementation shape:

1. Run `swift test --filter VoiceyTests` or a package-supported equivalent after `make build`.
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
