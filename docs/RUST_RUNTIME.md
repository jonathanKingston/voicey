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

Tracking issue: [#74](https://github.com/jonathanKingston/voicey/issues/74).

## CI tiers (Rust on Ubuntu)

| Tier | Job | Purpose |
|------|-----|---------|
| **1** | `rust-core` | Fast signal: protocol fixtures, supervisor integration (stubs), worker builds, benchmark script smoke tests |
| **2** | `rust-workspace` | Full `cargo test --workspace`, `clippy -D warnings` (includes `voicey-capture` ALSA deps) |

Workflow: [`.github/workflows/linux-rust-tests.yml`](../.github/workflows/linux-rust-tests.yml). Rust toolchain is pinned in [`rust-toolchain.toml`](../rust-toolchain.toml) (currently **1.86.0**).

Multi-process core for Voicey on macOS:

| Component | Binary | Hot path (default when bundled) |
|-----------|--------|----------------------------------|
| Infer | `Voicey infer-worker` | Qwen transcription |
| Supervisor | `voicey-supervisor` | Orchestrates infer + capture + fetch prewarm |
| Capture | `voicey-capture` | Hotkey microphone recording |
| Fetch | `voicey-fetch` | Qwen model file downloads |

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
