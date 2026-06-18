# Local steering benchmarks (developer-only)

These scripts measure **on-device** Qwen steering (glossary + optional screen snapshot replay). They are for **local macOS** runs with a built Rust runtime and downloaded models—not CI artifacts and not shipped product behavior.

## We never commit user audio or transcripts

**Do not add to git:**

- Session Archive **WAV** (or PCM) from dictation
- Full **transcripts** or post-process output from your machine
- Session Archive under `~/Library/Application Support/Voicey/SessionArchive/`
- Curated read-aloud bundles under `~/Library/Application Support/Voicey/Artifacts/` (`make export-readaloud-artifact`; zip `readaloud-corpus-v3/` for backup)
- Anything under `benchmark-data/` or `benchmark-results/` (already in `.gitignore`)

What **is** safe to commit:

- Python harness scripts under `scripts/`
- Text **manifests** such as [`readaloud_steering_corpus.json`](readaloud_steering_corpus.json): script lines, reference phrases, categories, and optional **8-character `id_prefix`** values that *point* to your local archive (not the audio itself)
- Golden JSON under `Benchmarks/Golden/steering/` (synthetic steering inputs/outputs, no speech)

Replay always reads WAV from **your** Session Archive path at run time. If a clip is missing locally, the harness skips or fails fast—it does not bundle or upload recordings.

## Related docs and PRs

- Recording script for the read-aloud corpus: [`ReadAloudSteeringRecording.md`](ReadAloudSteeringRecording.md)
- Production steering caps and sanitizer defaults: see PR [#191](https://github.com/jonathanKingston/voicey/pull/191) (`jkt/steering-context-caps`)
- Session archive (separate from this harness): dictation archive branch / [#181](https://github.com/jonathanKingston/voicey/pull/181)

## Quick commands (macOS)

```bash
make build-rust
make test-steering-benchmark-scripts   # unit tests only; no audio
```

Full sweeps (GPU, models, local archive):

```bash
python3 scripts/sweep_steering_caps.py --help
python3 scripts/eval_readaloud_artificial_steering.py --help
python3 scripts/broad_steering_analysis.py --help
```

Common Voice steering eval needs prepared clips under `benchmark-data/common-voice/` (`make benchmark-prepare-common-voice`). **ffmpeg** is required on macOS to convert MDC MP3 clips (`brew install ffmpeg`; `afconvert` alone cannot decode them).

LibriSpeech quality-matrix corpus: `make benchmark-prepare-librispeech-sample` (downloads dev-clean once). Resume CV/Libri steps into the latest full-eval folder: `make continue-full-model-evals` or `VOICEY_FULL_EVAL_OUT=benchmark-results/full-eval-… make continue-full-model-evals`.

## Cap overrides (harness IPC)

Sweep scripts call `voicey-text` `build_steering_context` with optional `max_screen_terms` and `max_context_character_count`. Omitted fields use the same defaults as the app (after #191: 8 / 32 / 256). Production Swift paths do not expose arbitrary cap grids—only this JSONL worker API for offline analysis.
