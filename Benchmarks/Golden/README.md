# Golden benchmark audio

Short mono WAV clips at 16 kHz for `benchmark-transcribe` checks against the **Rust multiprocess** runtime.

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

Set `VOICEY_BENCHMARK_WARMUP=1` (default in `compare_benchmark_runtime.sh`). Override model: `BENCHMARK_RUNTIME_PARITY_MODEL=qwen3-asr-1.7b-bf16`.
