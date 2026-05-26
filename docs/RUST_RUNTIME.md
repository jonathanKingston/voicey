# Voicey Rust runtime (macOS)

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

Copy runtime diagnostics from **Settings → Advanced** when reporting issues.

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
