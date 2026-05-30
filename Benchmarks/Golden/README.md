# Golden benchmarks

## Audio (WAV)

Short mono WAV clips at 16 kHz for `benchmark-transcribe` **smoke checks** against the **Rust multiprocess** runtime (RTF and JSON shape). Pure tones often produce an **empty** transcript; `make benchmark-compare-runtime` still passes when post-process and infer complete successfully.

Generate fixtures:

```bash
python3 scripts/generate_golden_fixtures.py
```

Run golden transcribe benchmark (requires `make build`, `make build-rust`, and a downloaded Qwen model):

```bash
make build
make build-rust
make benchmark-compare-runtime
make benchmark-runtime-parity-common-voice   # prepared Common Voice slice (25 clips)
make benchmark-measure-runtime-memory
```

Benchmark CLI defaults:

- `--runtime multiprocess` (Qwen rejects in-process)
- `--post-process` uses `voicey-text` (no Swift PostProcessor fallback)
- Model downloads use `voicey-fetch`

Set `VOICEY_BENCHMARK_WARMUP=1` (default in `compare_benchmark_runtime.sh`) for fair RTF. Override model: `BENCHMARK_RUNTIME_PARITY_MODEL=qwen3-asr-1.7b-bf16`.

## Post-process text (`postprocess/`)

JSON fixtures for the **Qwen / segment-less** `voicey-text` post-process contract (expansions, voice commands, pass-through without Whisper caption cleanup). Each file defines input text, optional segments, voice-command settings, and expected output.

Whisper noise-filter behavior is covered by `cargo test -p voicey-text --lib` (`noise_filter`, `postprocess` unit tests), not committed golden JSON.

Linux CI: `cargo test -p voicey-text --test golden_postprocess`

macOS: compare against Swift `PostProcessor` on the same inputs when validating a release.
