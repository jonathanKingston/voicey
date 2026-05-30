# Voicey Rust runtime (macOS)

IPC message shapes and contract tests: [`RUST_PROTOCOL.md`](RUST_PROTOCOL.md).

System map and code ownership: [`ARCHITECTURE.md`](ARCHITECTURE.md).

## Linux CI vs macOS validation

| Area | Linux CI (`linux-rust-tests`, `linux-core-tests`) | macOS CI / manual |
|------|---------------------------------------------------|-------------------|
| `voicey-protocol` fixtures + serde contract | Yes | — |
| Supervisor + stub workers (infer/capture/fetch) | Yes | — |
| `voicey-fetch` HTTP listing/download (local test server) | Yes | — |
| `voicey-capture` JSONL IPC + PCM fixture path (no microphone) | Yes | — |
| `voicey-text` / `VoiceyCore` unit tests | Yes (Rust + Swift) | — |
| Full SwiftUI app compile (`make build`) | No | Yes (`build.yml`) |
| MLX Qwen infer-worker, WER/RTF parity | No | Yes (`make run-multiprocess`, benchmark targets) |
| Mic capture (CoreAudio), TCC, auto-paste | No | Yes |
| Codesign, bundle, Sparkle, seatbelt on device | No | Yes |

Tracking issues:

- [#74](https://github.com/jonathanKingston/voicey/issues/74) — Rust CI and Linux testability
- [#70](https://github.com/jonathanKingston/voicey/issues/70) — Rust-first transition; **when Swift duplicate paths can be removed** (Phases 1–6)

### Can Swift duplicates be removed yet? (May 2026)

**No.** Bundled production still needs Swift fallbacks and the Swift MLX infer subprocess. Rust workers and `voicey-text` are additive until Phase 2 in #70.

| Layer | Rust | Swift still required because |
|-------|------|------------------------------|
| Capture | `voicey-capture` (default when bundled) | `AVAudioEngine` fallback (`VOICEY_USE_RUST_CAPTURE=0`, dev disable) |
| Fetch | `voicey-fetch` | `HuggingFaceDownloader` fallback |
| Post-process | `voicey-text` worker when bundled (#63) | Swift `PostProcessor` fallback on worker error / `VOICEY_USE_RUST_TEXT=0`; Whisper caption noise filter only when `segments` non-empty (benchmark) |
| Text / glossary | `voicey-text` | `VoiceyCore` in host |
| Infer | — | `QwenEngine` in Swift `infer-worker` |
| PCM files | `voicey-pcm` | `SharedMemoryPCM.swift` (infer read, `[Float]` path, benchmarks) |

Phase 1 PCM pass-through for manual + hands-free Rust capture is landed (#82, #84). Deletion of fallbacks is Phase 2 in #70.

## CI tiers (Rust on Ubuntu)

| Tier | Job | Purpose |
|------|-----|---------|
| **1** | `rust-core` | Fast signal: protocol fixtures, supervisor `process.rs` unit tests (`--bin voicey-supervisor`), stub integration, capture IPC, fetch unit/HTTP tests, worker builds, benchmark script smoke tests |
| **2** | `rust-workspace` | Full `cargo test --workspace`, `clippy -D warnings` (includes `voicey-capture` ALSA deps) |

Workflow: [`.github/workflows/linux-rust-tests.yml`](../.github/workflows/linux-rust-tests.yml). Rust toolchain is pinned in [`rust-toolchain.toml`](../rust-toolchain.toml) (currently **1.86.0**).

Multi-process core for Voicey on macOS:

| Component | Binary | Hot path (default when bundled) |
|-----------|--------|----------------------------------|
| Infer | `Voicey infer-worker` | Qwen transcription |
| Supervisor | `voicey-supervisor` | Orchestrates infer + capture + fetch prewarm |
| Capture | `voicey-capture` | Hotkey microphone recording |
| Fetch | `voicey-fetch` | Qwen model file downloads |
| Text post-process | `voicey-text` | Expansions, voice commands after infer; Whisper noise filter only with segments (benchmark) |

Mic capture, UI, and paste remain in the main app process unless noted above.

## Defaults

After `make build-rust` and `make bundle-debug`, workers live in `Voicey.app/Contents/MacOS/`. Voicey **auto-enables** each worker when its binary is present.

| Override | Effect |
|----------|--------|
| `VOICEY_DISABLE_RUST_WORKERS=1` | Disable all Rust workers (Swift fallbacks) |
| `VOICEY_USE_RUST_SUPERVISOR=0` | Direct infer-worker IPC (no supervisor) |
| `VOICEY_USE_RUST_FETCH=0` | Hub-based Qwen downloads |
| `VOICEY_USE_RUST_CAPTURE=0` | AVAudioEngine mic capture |
| `VOICEY_USE_RUST_TEXT=0` | Swift `PostProcessor` only (no `voicey-text` worker) |
| `VOICEY_RUNTIME=in-process` | Qwen MLX inside main app |
| `VOICEY_USE_FETCH_SANDBOX=0` | Disable the bundled default seatbelt profile for `voicey-fetch` in direct builds |
| `VOICEY_FETCH_SANDBOX_PROFILE=/path/to/profile.sb` | Launch `voicey-fetch` via `sandbox-exec -f` with the given seatbelt profile |
| `VOICEY_FETCH_HF_BASE_URL` | Override Hugging Face API base URL (tests and local debugging only; production uses `https://huggingface.co`) |

Copy runtime diagnostics from **Settings → Advanced** when reporting issues.

## Fetch worker contract

`voicey-fetch` now owns the Hugging Face tree listing + file download path for bundled Qwen downloads:

- the app asks the worker to list matching repo files for a model;
- the worker constructs the Hugging Face URLs itself;
- downloads are staged under an isolated temp root and only promoted into the live model cache once the full tree is present;
- the worker rejects absolute paths, traversal, and malformed model IDs.

That keeps the main app off the Qwen listing hot path and narrows the worker's authority versus the older raw `url + staging_path` contract.

In direct-distribution builds, Voicey now defaults `voicey-fetch` to a bundled seatbelt profile unless `VOICEY_USE_FETCH_SANDBOX=0` disables it. `VOICEY_FETCH_SANDBOX_PROFILE` still overrides the profile path for local testing.

## Text worker contract (`voicey-text`)

After infer returns raw text, the host may delegate to `voicey-text` over JSONL (`ping`, `postprocess`, `shutdown`):

- **Segment-less backends (Qwen):** `segments` is empty; Whisper caption noise filter and intelligent punctuation are skipped (same as Swift `PostProcessor`).
- **Segmented backends (benchmark Whisper):** optional `segments` with `start_time` / `end_time` enable noise filter and pause-based punctuation.
- **Voice commands:** host sends enabled commands as structured JSON; settings are snapshotted per request.
- **Golden parity:** `Benchmarks/Golden/postprocess/*.json` — `cargo test -p voicey-text --test golden_postprocess`.

Swift falls back to in-process `PostProcessor` if the worker is missing or returns an error.

## Build & run

```bash
make build-rust          # builds + copies workers to .build/debug/
make run-multiprocess    # bundle-debug + sign + open Voicey.app
```

## Benchmarks

See commands in the previous sections of this doc (`benchmark-transcribe --runtime`, `make benchmark-runtime-parity-common-voice`, etc.).

## XPC (P4)

Set `VOICEY_USE_XPC=1` for entitlement-split stubs under `Resources/XPC/`.

See [CROSS_PLATFORM_DEFERRED.md](CROSS_PLATFORM_DEFERRED.md) for Linux/Windows follow-up work.
