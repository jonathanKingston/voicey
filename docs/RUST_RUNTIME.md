# Voicey Rust runtime (macOS)

IPC message shapes and contract tests: [`RUST_PROTOCOL.md`](RUST_PROTOCOL.md).

System map and code ownership: [`ARCHITECTURE.md`](ARCHITECTURE.md).

## Linux CI vs macOS validation

This table is the **M5 allowlist** for [#74](https://github.com/jonathanKingston/voicey/issues/74): what every PR must pass on Ubuntu vs what still needs a Mac.

| Area | Linux CI owns | macOS CI / manual only |
|------|---------------|------------------------|
| `voicey-protocol` fixtures + serde contract | Yes (`make protocol-fixtures`, Swift fixture decode) | — |
| Supervisor + stub workers (infer/capture/fetch) | Yes (integration tests, worker I/O) | — |
| `voicey-fetch` HTTP listing/download (local test server) | Yes (`cargo test -p voicey-fetch`, Tier 1) | — |
| `voicey-capture` JSONL IPC + PCM fixture path (no microphone; includes `drain_hands_free_utterance`, `read_captured_samples`) | Yes | — |
| `voicey-text` unit + golden postprocess / steering | Yes (`cargo test -p voicey-text`, `linux-core-tests`) | — |
| Benchmark harness **scripts** (Common Voice prep, parity matrix smoke) | Yes (`test-common-voice-benchmark`, Tier 1 script checks) | — |
| Benchmark **Qwen transcribe RTF / WER** (needs MLX + models) | No | Yes (`make benchmark-compare-runtime`, parity targets) |
| Full SwiftUI app compile | No | Yes (`build.yml`) |
| MLX Qwen `infer-worker`, live dictation | No | Yes (`make run-multiprocess`) |
| Mic capture (CoreAudio), TCC, auto-paste | No | Yes |
| Codesign, bundle, Sparkle, seatbelt on device | No | Yes (`make bundle-direct`, release scripts) |

**Local quick check (Linux / Cloud Agent):** `make protocol-fixtures`, `cargo test -p voicey-protocol -p voicey-supervisor --bin voicey-supervisor -p voicey-fetch -p voicey-text`, `swift test --filter VoiceyCoreTests`, `swiftlint lint Sources/`.

**Local quick check (macOS):** `make build && make build-rust && make run-multiprocess`; before release: `make benchmark-compare-runtime` and spot-check hands-free ([#99](https://github.com/jonathanKingston/voicey/issues/99)).

Tracking issues:

- [#74](https://github.com/jonathanKingston/voicey/issues/74) — Rust CI and Linux testability ([`ISSUE_74_PROGRESS.md`](ISSUE_74_PROGRESS.md))
- [#70](https://github.com/jonathanKingston/voicey/issues/70) — Rust-first transition; **when Swift duplicate paths can be removed** (Phases 1–6)

### Can Swift duplicates be removed yet? (May 2026)

**Partially.** The text post-process / steering Swift duplicates are **removed** — `voicey-text` is mandatory there. Capture (`AVAudioEngine`), fetch (`HuggingFaceDownloader`), and the Swift MLX infer subprocess still have Swift paths (Phase 2+ in #70).

| Layer | Rust | Swift still required because |
|-------|------|------------------------------|
| Capture | `voicey-capture` (default when bundled) | `AVAudioEngine` only when worker absent or `VOICEY_USE_RUST_CAPTURE=0` / `VOICEY_DISABLE_RUST_WORKERS=1`; worker errors fail fast (no silent empty capture) |
| Fetch | `voicey-fetch` | `HuggingFaceDownloader` fallback |
| Post-process | `voicey-text` worker (required) | **Removed** — no Swift `PostProcessor` fallback; the worker is mandatory and errors fail fast |
| Text / glossary | `voicey-text` (required) | **Removed** — steering + post-process always run on `voicey-text`; no in-process Swift path |
| Infer | — | `QwenEngine` in Swift `infer-worker` |
| PCM files | `voicey-pcm` | `SharedMemoryPCM.swift` (infer read, `[Float]` path, benchmarks); temp `voicey_pcm_*.pcm` files use owner-only `0600` permissions with startup/shutdown stale cleanup |

Phase 1 PCM pass-through for manual hotkey and hands-free `drain_hands_free_utterance` is landed (#82, #84, #126, #129; hands-free drain keeps `PCMBufferHandle` without Swift PCM read). `voicey-capture` `read_captured_samples` streams PCM into the incremental coordinator on the Rust capture path (parity with AVFoundation `didCaptureSamples`; macOS QA: [`MACOS_MANUAL_QA.md`](MACOS_MANUAL_QA.md), [#145](https://github.com/jonathanKingston/voicey/issues/145)). Utterance finish routing (#129, #159) uses shared PCM when the coordinator has no streamed audio. Phase 2 (#70) is in progress: post-process, capture, and steering/glossary (via `build_steering_context` on `voicey-text`) no longer fall back to Swift when bundled workers are enabled; worker errors surface to the user. Deletion of remaining opt-out fallbacks (AVAudioEngine / Hub / infer) is still Phase 2+. Benchmark Phase 3 (#124, #125) no longer reads PCM in Swift.

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

After infer returns raw text, the host delegates to `voicey-text` over JSONL (`ping`, `postprocess`, `build_steering_context`, `shutdown`). This is the only post-process / steering path; there is no in-process Swift fallback:

- **Segment-less backends (Qwen):** `segments` is empty; Whisper caption noise filter and intelligent punctuation are skipped.
- **Steering-echo stripping:** `postprocess` receives the utterance `decoder_context` + `steering_terms` and strips regurgitated steering vocabulary before any other cleanup (issue #162).
- **Segmented backends (benchmark Whisper):** optional `segments` with `start_time` / `end_time` enable noise filter and pause-based punctuation.
- **Voice commands:** host sends enabled commands as structured JSON; settings are snapshotted per request.
- **Steering / glossary:** host sends manual glossary settings and optional accessibility snapshot; worker returns decoder context via BM25 term selection in Rust.
- **Golden parity:** `Benchmarks/Golden/postprocess/*.json` — `cargo test -p voicey-text --test golden_postprocess`; `Benchmarks/Golden/steering/*.json` — `cargo test -p voicey-text --test golden_steering`. (Steering + post-process run only on `voicey-text`; the Swift mirrors and their golden tests were removed.)

The `voicey-text` worker is required for post-process and steering; worker errors propagate to the host (no Swift fallback).

## Build & run

```bash
make build-rust          # builds + copies workers to .build/debug/
make build-rust-release  # release workers (strip debug symbols; see Cargo.toml [profile.release])
make run-multiprocess    # bundle-debug + sign + open Voicey.app
```

Release workers use the workspace `[profile.release]` profile (`strip = true`, merged in [#119](https://github.com/jonathanKingston/voicey/pull/119)). Thin LTO (`lto = "thin"`, `codegen-units = 1`) is deferred until `make build-rust-release` wall time is measured on macOS — track in a follow-up comment on closed [#73](https://github.com/jonathanKingston/voicey/issues/73).

## Benchmarks

Benchmark CLIs and harnesses exercise the **bundled Rust worker stack** (no Swift duplicate fallbacks on the Qwen path). Merged in [#105](https://github.com/jonathanKingston/voicey/pull/105); golden notes in [`Benchmarks/Golden/README.md`](../Benchmarks/Golden/README.md).

| Command / target | Requires | Notes |
|------------------|----------|-------|
| `make benchmark-golden-fixtures` | `cargo test -p voicey-text --test golden_postprocess` | Linux CI |
| `make benchmark-compare-runtime` | `make build`, `make build-rust`, Qwen model | macOS; `BenchmarkRustRequirements` |
| `benchmark-transcribe` (Qwen) | supervisor + infer-worker + capture (`load_wav_file`); `--post-process` → `voicey-text` | Qwen multiprocess decodes WAV in Rust ([#70](https://github.com/jonathanKingston/voicey/issues/70) Phase 3); in-process Whisper/Granite still use AVFoundation |
| `benchmark-capture-compare` | `voicey-capture` `record_fixture` metadata only | No Swift PCM read on fixture smoke ([#70](https://github.com/jonathanKingston/voicey/issues/70) Phase 3) |
| `make benchmark-runtime-parity-common-voice` | prepared Common Voice slice + workers | macOS WER/RTF matrix |
| `python3 scripts/test_common_voice_benchmark.py` | none (harness smoke) | Linux CI Tier 1 |

Qwen benchmarks reject `VOICEY_RUNTIME=in-process`. Whisper/Granite remain for parity tooling only, not the settings UI hot path.

## XPC (P4)

Set `VOICEY_USE_XPC=1` for entitlement-split stubs under `Resources/XPC/`.

See [CROSS_PLATFORM_DEFERRED.md](CROSS_PLATFORM_DEFERRED.md) for Linux/Windows follow-up work.
