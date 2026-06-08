# Common Voice Benchmark Test Bed

This benchmark harness runs Voicey's real model wrappers against a small,
deterministic sample from a Mozilla Common Voice TSV split. It is intended as a
quick first pass for comparing models before investing in a larger Voicey-specific
dictation set.

## Dataset

Download Common Voice from Mozilla Data Collective:

<https://datacollective.mozillafoundation.org/>

Use a `test.tsv` or `dev.tsv` split and its matching `clips/` directory. Keep the
dataset outside git; Common Voice data should not be committed, mirrored, or
re-hosted.

## Quick start

The default sample size is intentionally small: `--limit 25`. Increase it only
after the command path is stable.

```bash
# One-time: create an MDC API key, accept the English dataset terms on Mozilla
# Data Collective, and export the key or put it in an untracked .env file.
export MDC_API_KEY=...
make benchmark-run-common-voice
```

`make benchmark-run-common-voice` does three things:

1. Builds `.build/debug/Voicey`.
2. Downloads missing benchmark models with `Voicey benchmark-download-models`.
3. Downloads the small Common Voice English spontaneous speech archive from MDC
   and extracts the sampled clips into `benchmark-data/`.

Results are written to `benchmark-results/` as:

- `*.jsonl` — one record per model per clip
- `*_summary.json` — aggregate WER/CER and optional speed metrics
- `*_examples.md` — best/median/worst examples per model and side-by-side predictions

## Useful options

```bash
# Larger deterministic sample
make benchmark-run-common-voice BENCHMARK_COMMON_VOICE_LIMIT=100

# Continue recording failures instead of failing fast
make benchmark-common-voice ARGS='... --keep-going'

# Choose the compared models
make benchmark-run-common-voice BENCHMARK_VOICEY_MODELS='large-v3_turbo small.en base.en'

# Compare normal full-buffer transcription against pause-based piecemeal transcription
python3 scripts/benchmark_common_voice.py \
  --tsv benchmark-data/common-voice/prepared/.../test.tsv \
  --clips-dir benchmark-data/common-voice/prepared/.../clips \
  --limit 25 \
  --voicey-model small.en \
  --voicey-incremental-model small.en

# Prepare data only. Add ARGS='--install-sdk' to install the MDC Python SDK.
make benchmark-prepare-common-voice ARGS='--install-sdk'
```

By default the benchmark fails fast on missing files, non-zero commands, empty
transcripts, and timeouts.

## Interpreting Results

- **WER** is word error rate: word insertions, deletions, and substitutions
  divided by the number of reference words. `0.11` roughly means 11 word-level
  errors per 100 reference words. Lower is better.
- **CER** is the same idea at character level. It is useful when wording is close
  but spacing, suffixes, or small spelling differences vary. Lower is better.
- **RTF** is real-time factor: transcription seconds divided by audio seconds.
  `0.25` means the model transcribed at about 4x real time. Lower is faster.
  This excludes initial model load/CoreML warmup time.

`large-v3_turbo` is excluded from the default model list because first-load
warmup/CoreML compilation dominates local benchmark time. Add it explicitly with
`BENCHMARK_VOICEY_MODELS=...` when you want to compare it.

## Dataset Download Notes

The default dataset is Common Voice Spontaneous Speech 3.0 English:

```text
cmn1pv5hi00uto1072y1074y7
```

It is about 459 MB and is a better fit for Voicey than scripted read speech
because it contains spontaneous responses. The prep script also supports the
larger scripted English archive in streaming mode, but MDC does not expose a
split/sample endpoint.

To try the 87.84 GB scripted English archive without saving the whole archive,
use streaming mode:

```bash
export MDC_API_KEY=...
make benchmark-run-common-voice \
  BENCHMARK_COMMON_VOICE_SOURCE=mdc-stream \
  BENCHMARK_COMMON_VOICE_DATASET=cmndapwry02jnmh07dyo46mot \
  BENCHMARK_VOICEY_MODELS='large-v3_turbo small.en base.en'
```

You must accept the dataset terms on Mozilla Data Collective before MDC allows
download.

## Single-file wrapper check

Use this to verify a downloaded model can transcribe one audio file before running
the full Common Voice loop:

```bash
.build/debug/Voicey benchmark-transcribe \
  --model qwen3-asr-0.6b-6bit \
  --audio /path/to/cv-corpus/clips/common_voice_en_123.mp3
```

Add `--json` to include processing time, audio duration, and real-time factor in
a single machine-readable line. Add `--post-process` to run Voicey's
`PostProcessor` before printing the text.

Download models without running the benchmark:

```bash
.build/debug/Voicey benchmark-download-models large-v3_turbo small.en base.en
```

Use `--all` to download every `SpeechModel` case.

## Apple SpeechAnalyzer comparison (macOS 26+)

A standalone eval CLI lives under [`Benchmarks/AppleSpeech/README.md`](AppleSpeech/README.md).
It plugs into this same harness via `--apple-speech`:

```bash
make build-apple-speech-benchmark
make benchmark-run-apple-speech-vs-qwen-common-voice
```

That runs Qwen 1.7B (multiprocess + post-process) and Apple offline SpeechTranscriber on
the same deterministic Common Voice slice.

## What this is good for

- Quick WER/CER comparisons across Voicey's model wrappers
- Regression checks when model settings change
- Accent and speaker diversity from Common Voice
- Head-to-head Apple Speech vs Qwen spikes before any product backend change
- Comparing processing time across the same selected clips
- Comparing batch transcription against the pause-based piecemeal path on the
  same deterministic clips. Use paired `--voicey-model MODEL` and
  `--voicey-incremental-model MODEL` runs; the summary labels the results as
  `MODEL:batch` and `MODEL:incremental`.

## What it does not prove

Most Common Voice scripted speech is read aloud. Voicey is a dictation app, so
this benchmark should eventually be paired with a smaller in-house set covering
spontaneous dictation, pauses, corrections, background noise, silence, and
punctuation-heavy examples.
