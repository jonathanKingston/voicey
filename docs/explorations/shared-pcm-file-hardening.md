# Shared PCM File Hardening

## Status

Implemented on `main` (owner-only permissions, observable cleanup, stale-file sweep). See `voicey-pcm` and `SharedMemoryPCM.swift`.

## Summary

The multiprocess runtime writes raw audio samples to temporary `voicey_pcm_*.pcm` files so Swift
and Rust worker processes can share captured audio. Those files should be created with explicit
owner-only permissions and predictable cleanup behavior because they contain microphone input.

## Evidence

- `SharedMemoryPCM.write(samples:)` writes `Data` to `FileManager.default.temporaryDirectory`
  with `.atomic`.
- File names use the `voicey_pcm_` prefix plus a UUID without dashes.
- `SharedMemoryPCM.remove(name:)` silently ignores cleanup failures.
- The Rust `voicey-pcm` crate documents the same temp-directory protocol.

Relevant files:

- `Sources/Voicey/Runtime/SharedMemoryPCM.swift`
- `crates/voicey-pcm/src/lib.rs`
- `docs/RUST_RUNTIME.md`
- `docs/RUST_PROTOCOL.md`

## Risks

- Default temp-file permissions may not express the intended audio confidentiality guarantee.
- Crashes or forced termination can leave raw PCM files behind.
- Cleanup failures are silent, which makes leaks hard to diagnose.
- Swift and Rust implementations can diverge if permission semantics are not documented.

## Proposed direction

Make the PCM file contract explicit: temp files contain sensitive audio, must be owner-only, and
must be cleaned up promptly by both normal and best-effort shutdown paths.

Possible implementation shape:

1. Create files with owner-only permissions such as `0600`.
2. Keep atomic-write behavior while preserving restrictive permissions.
3. Log cleanup failures without exposing file contents.
4. Add startup or shutdown cleanup for stale `voicey_pcm_*.pcm` files owned by Voicey.
5. Document the permissions contract in Swift, Rust, and runtime docs.

## Acceptance criteria

- Shared PCM files are created with explicit owner-only permissions.
- Swift and Rust agree on the file permission and cleanup contract.
- Cleanup failures are observable in logs.
- Stale files are removed on normal app shutdown and best-effort startup cleanup.
- Tests verify file mode where supported by the platform.

## Validation plan

- Add a unit test that writes a PCM file and checks mode bits on macOS/Linux where available.
- Add a cleanup test using a temporary directory override if the API supports it.
- On macOS, run a transcription through the Rust runtime and verify temp files do not remain.
