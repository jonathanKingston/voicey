# Swift Hot-Path Fallback Deletion (Phase 2+)

## Status

Exploratory proposal. Tracking issue: [#152](https://github.com/jonathanKingston/voicey/issues/152) (parent [#70](https://github.com/jonathanKingston/voicey/issues/70)).

**Blocked on:** merge of [#150](https://github.com/jonathanKingston/voicey/pull/150) (screen-context gate). [#138](https://github.com/jonathanKingston/voicey/pull/138) and [#166](https://github.com/jonathanKingston/voicey/pull/166) are on `main`; [#145](https://github.com/jonathanKingston/voicey/issues/145) macOS QA is closed.

## Summary

Bundled production builds already default to Rust workers for capture, fetch, and post-process. Swift
duplicate paths remain as opt-out fallbacks (`VOICEY_DISABLE_RUST_WORKERS=1`, per-layer `=0` flags).
Phase 2+ deletes those fallbacks so the bundled happy path has no silent Swift duplicate logic.

## Evidence

### Capture — `AVAudioEngine` fallback

- `AudioCaptureManager.startCapture()` branches on `VoiceyRuntimeConfiguration.useRustCaptureHotPath`.
- When false, it creates `AVAudioEngine`, installs an input tap, resamples to 16 kHz, and buffers
  samples in Swift (`audioBuffer`).
- Rust path uses `VoiceyCaptureWorkerSession`; errors fail fast (no silent empty capture).
- Incremental PCM streaming on the Rust path is on `main` (#138, #166); capture fallback deletion should follow [#150](https://github.com/jonathanKingston/voicey/pull/150) merge.

Relevant files:

- `Sources/Voicey/Audio/AudioCaptureManager.swift`
- `Sources/Voicey/Runtime/VoiceyRuntimeConfiguration.swift` (`useRustCaptureHotPath`, `VOICEY_USE_RUST_CAPTURE`)
- `Sources/Voicey/App/AppDelegate.swift` (incremental coordinator wiring)

### Fetch — `HuggingFaceDownloader` fallback

- `ModelManager` Qwen download uses `VoiceyRustQwenDownloader` when `useRustFetch` is true, else
  `HuggingFaceDownloader.downloadWeights`.
- Cache validation still references `HuggingFaceDownloader` helpers (`getCacheDirectory`, `weightsExist`).
- `VoiceyRustQwenDownloader` reuses HuggingFace path validation helpers for staged files.

Relevant files:

- `Sources/Voicey/Transcription/ModelManager.swift`
- `Sources/Voicey/Runtime/VoiceyRustQwenDownloader.swift`
- `Sources/Voicey/Runtime/VoiceyRuntimeConfiguration.swift` (`useRustFetch`, `VOICEY_USE_RUST_FETCH`)

### Post-process — Swift `PostProcessor` fallback

- `PostProcessor.process` / `processAsync` branch on `VoiceyRuntimeConfiguration.useRustTextPostProcess`.
- Rust path delegates to `VoiceyTextWorkerSession`; errors throw (no Swift fallback on worker failure).
- Swift `processInSwift` remains for opt-out / missing worker.

Relevant files:

- `Sources/Voicey/Transcription/PostProcessor.swift`
- `Sources/Voicey/Runtime/VoiceyRuntimeConfiguration.swift` (`useRustTextPostProcess`, `VOICEY_USE_RUST_TEXT`)

### Global opt-out

- `VOICEY_DISABLE_RUST_WORKERS=1` disables all Rust worker hot paths via `VoiceyRuntimeConfiguration.rustWorkersDisabled`.

Documented in [`RUST_RUNTIME.md`](../RUST_RUNTIME.md).

## Risks

- Removing capture fallback before incremental streaming was validated broke the Rust path; that gate is cleared on `main` (#138, #166, #145).
- Hub downloader removal must preserve cache layout and revision tracking used by `ModelManager`.
- Deleting Swift post-process without bundled `voicey-text` breaks dev builds that skip `make build-rust`.
- Benchmark CLIs already require Rust workers (PR #69 direction); app hot path should match.

## Proposed direction

Land in separate PRs (order from #152):

1. **Capture** — delete `AVAudioEngine` hot path and trailing trim in Swift; require bundled
   `voicey-capture`. Keep `#if DEBUG` escape hatch only if needed for local dev without Rust build.
2. **Fetch** — delete Hub download branch for Qwen; require `voicey-fetch`. Retain shared path/cache
   validation helpers or move them to a thin Swift utility with no network I/O.
3. **Text** — delete `processInSwift` from production path; require `voicey-text`.
4. **Docs** — update `RUST_RUNTIME.md` “Can Swift duplicates be removed yet?” to **Yes** per layer.

Decide explicitly whether `VOICEY_DISABLE_RUST_WORKERS=1` remains for local dev only or is removed.

## Acceptance criteria

- Bundled `make bundle-debug` happy path emits no Swift fallback logs for capture, fetch, or post-process.
- Linux CI unchanged or stricter (`VoiceyCore` / Rust tests).
- macOS spot-check: hotkey dictation, hands-free multi-utterance, model download (see [`MACOS_MANUAL_QA.md`](../MACOS_MANUAL_QA.md)).
- Capture PR lands after [#150](https://github.com/jonathanKingston/voicey/pull/150) merge (combined screen-context + incremental chunk validation).

## Validation plan

- Grep-based CI guard (optional): no `AVAudioEngine` in `AudioCaptureManager` production path.
- Existing stub integration tests cover Rust worker IPC; extend only where deletion changes error surfaces.
- macOS manual QA per [`MACOS_MANUAL_QA.md`](../MACOS_MANUAL_QA.md) after each layer lands.
