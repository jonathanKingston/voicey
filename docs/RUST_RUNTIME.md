# Voicey Rust runtime (macOS)

Multi-process core for Voicey on macOS:

| Component | Infer worker | Capture worker | Fetch worker | Supervisor |
|-----------|--------------|----------------|--------------|------------|
| Binary | `Voicey infer-worker` | `voicey-capture` | `voicey-fetch` | `voicey-supervisor` |
| Role | Qwen MLX transcription | Mic / fixture capture | HTTPS staging downloads | JSONL orchestration |

## Qwen infer worker (default)

Qwen models run in a separate **`Voicey infer-worker`** process by default. Mic capture, UI, and paste remain in the main app.

| Environment | Effect |
|-------------|--------|
| `VOICEY_RUNTIME=in-process` | Force in-app Qwen MLX (support / benchmarks) |
| `VOICEY_USE_RUST_SUPERVISOR=1` | Route infer/capture prewarm through **`voicey-supervisor`** |
| `VOICEY_USE_RUST_FETCH=1` | Preflight Qwen downloads with **`voicey-fetch`** (fail fast if worker missing) |
| `VOICEY_USE_RUST_CAPTURE=1` | Prewarm **`voicey-capture`** via long-lived session |
| `VOICEY_USE_XPC=1` | XPC entitlement split (stubs under `Resources/XPC/`) |

Worker paths resolve from `Voicey.app/Contents/MacOS/` after `make build-rust`, or `.build/debug/` when developing.

Copy runtime diagnostics from **Settings → Advanced** when reporting issues.

## Build

```bash
make build-rust   # copies workers to .build/debug/
make build
```

## Benchmarks

```bash
Voicey benchmark-transcribe --model qwen3-asr-0.6b-6bit --audio Benchmarks/Golden/tone_0p5s_440hz.wav --runtime multiprocess --warmup 1 --json
scripts/compare_benchmark_runtime.sh          # VOICEY_BENCHMARK_WARMUP=1 for both runtimes (default)
make benchmark-compare-runtime
make benchmark-runtime-parity-common-voice    # all clips in prepared Common Voice TSV
make benchmark-runtime-parity-common-voice BENCHMARK_RUNTIME_PARITY_MODEL=qwen3-asr-1.7b-bf16
make benchmark-measure-runtime-memory         # time -l peaks + MLX / ps RSS note
Voicey benchmark-capture-compare
```

`make benchmark-runtime-parity-common-voice` requires `make benchmark-prepare-common-voice` first. Writes `benchmark-results/runtime-parity-common-voice-*.json`.

`make benchmark-measure-runtime-memory` reports in-process peak RSS from `/usr/bin/time -l`. **MLX model memory is often under-reported by `ps RSS`** on a warm `infer-worker`; use peak RSS and `SpeechModel.memoryUsage` in ModelManager for capacity planning.

## XPC (P4)

Set `VOICEY_USE_XPC=1` to use XPC service entitlements under `Resources/XPC/`. Subprocess mode is the default path.

See [CROSS_PLATFORM_DEFERRED.md](CROSS_PLATFORM_DEFERRED.md) for Linux/Windows follow-up work.
