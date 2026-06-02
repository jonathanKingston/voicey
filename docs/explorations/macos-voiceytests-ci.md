# macOS VoiceyTests CI

## Status

**Implemented** on `main` in [#189](https://github.com/jonathanKingston/voicey/pull/189) (follow-up to exploration [#116](https://github.com/jonathanKingston/voicey/pull/116)).

- `.github/workflows/build.yml`: `swift test --filter VoiceyTests` after `make build`
- Failed runs upload `voiceytests.log` as a workflow artifact (14-day retention)

## Summary

macOS CI runs the entire `VoiceyTests` target (45 headless tests across 9 classes). Linux CI
continues to run `VoiceyCoreTests` only (`.github/workflows/linux-core-tests.yml`).

Previously, CI used a hand-maintained five-class `--filter` allowlist that omitted
`ClipboardManagerTests`, `ScreenContextStoreTests`, `TranscriptionOverlayControllerTests`, and
`VoiceySingleInstanceTests`.

## CI vs manual testing

| Layer | Where | Notes |
|-------|-------|-------|
| `VoiceyCoreTests` | Linux + macOS (via full package test on Mac) | No Apple frameworks |
| `VoiceyTests` | macOS `build.yml` only | Headless; no microphone or Screen Recording TCC |
| Hands-free, overlay UX, model download | [`MACOS_MANUAL_QA.md`](../MACOS_MANUAL_QA.md) | Required for merge gates on #150, #169, #152 |

`VoiceyTests` do not require a separate `make build-rust` step: they exercise in-process helpers,
shared-memory PCM, mocks, and configuration — not live worker processes.

## Risks (mitigated)

- ~~App-layer regressions in unlisted classes could pass CI~~ — full target now runs.
- ~~New test classes drift off the allowlist~~ — default is the whole target.
- macOS-specific runtime behavior still needs manual QA for integration paths not covered by unit tests.

## Optional follow-ups (deferred)

- Deliberately failing test once to confirm CI blocks merges (one-off validation).
- Split slow vs fast macOS jobs if `VoiceyTests` runtime becomes a bottleneck.

## Acceptance criteria

- [x] macOS CI runs the app-layer `VoiceyTests` target.
- [x] Failures block pull requests.
- [x] Worker / MLX setup documented in the workflow (see `build.yml` header).
- [x] Manual-only tests documented in [`MACOS_MANUAL_QA.md`](../MACOS_MANUAL_QA.md).
- [x] New app-layer behavior has a clear place to add regression tests (`Tests/VoiceyTests`).
