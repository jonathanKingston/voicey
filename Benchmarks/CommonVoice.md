# Common Voice Benchmark Test Bed

This benchmark harness runs local ASR commands against a small, deterministic
sample from a Mozilla Common Voice TSV split. It is intended as a quick first
pass for comparing models before investing in a larger Voicey-specific dictation
set.

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
make benchmark-common-voice ARGS='\
  --tsv /path/to/cv-corpus/test.tsv \
  --clips-dir /path/to/cv-corpus/clips \
  --model-command "model-a=/path/to/transcribe --audio {audio}" \
  --model-command "model-b=/path/to/transcribe-alt --audio {audio}"'
```

Each `--model-command` must be `NAME=COMMAND`. The command must include the
`{audio}` placeholder and print the transcript to stdout. Results are written to
`benchmark-results/` as:

- `*.jsonl` — one record per model per clip
- `*_summary.json` — aggregate WER/CER and optional speed metrics

## Useful options

```bash
# Larger deterministic sample
--limit 100 --seed 20260506

# Extract transcript from noisy stdout
--transcript-regex '^TRANSCRIPT:\s*(?P<text>.*)$'

# Continue recording failures instead of failing fast
--keep-going

# Measure real-time factor when ffprobe is installed
--measure-duration
```

By default the benchmark fails fast on missing files, non-zero commands, empty
transcripts, and timeouts.

## What this is good for

- Quick WER/CER comparisons across model commands
- Regression checks when model settings change
- Accent and speaker diversity from Common Voice
- Comparing processing time across the same selected clips

## What it does not prove

Most Common Voice scripted speech is read aloud. Voicey is a dictation app, so
this benchmark should eventually be paired with a smaller in-house set covering
spontaneous dictation, pauses, corrections, background noise, silence, and
punctuation-heavy examples.
