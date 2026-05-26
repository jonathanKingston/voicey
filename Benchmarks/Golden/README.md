# Golden benchmark audio

Short mono WAV clips at 16 kHz for `benchmark-transcribe` parity checks.

Generate fixtures:

```bash
python3 scripts/generate_golden_fixtures.py
```

Compare in-process vs multiprocess (requires a downloaded Qwen model):

```bash
make build
make benchmark-compare-runtime
make benchmark-runtime-parity-common-voice   # full prepared Common Voice slice (25 clips)
make benchmark-measure-runtime-memory
```

Set `VOICEY_BENCHMARK_WARMUP=1` (default in `compare_benchmark_runtime.sh`) for fair RTF. Override model: `BENCHMARK_RUNTIME_PARITY_MODEL=qwen3-asr-1.7b-bf16`.
