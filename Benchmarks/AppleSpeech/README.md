# Apple Speech benchmark (local macOS)

Offline batch transcription via `SFSpeechRecognizer` for comparing Apple Speech against Qwen on prepared WAV clips.

## Build

```bash
make build-apple-speech-benchmark
```

Binary: `Benchmarks/AppleSpeech/voicey-apple-speech-benchmark.app`

The Makefile bundles the CLI into a minimal `.app` so macOS loads `NSSpeechRecognitionUsageDescription`.

**First run:** macOS prompts for Speech Recognition — approve for `voicey-apple-speech-benchmark`. If the eval fails with no output, check System Settings → Privacy & Security → Speech Recognition.

## Build

```bash
make build-apple-speech-benchmark
```

## Usage

Single file (via app bundle):

```bash
open -W -n Benchmarks/AppleSpeech/voicey-apple-speech-benchmark.app --args --wav path/to/clip.wav
```

Batch (used by rerank eval; writes NDJSON via `--output`):

```bash
open -W -n Benchmarks/AppleSpeech/voicey-apple-speech-benchmark.app --args \
  --tsv benchmark-data/.../test.tsv \
  --clips-dir benchmark-data/.../clips \
  --output /tmp/apple.ndjson
```

## Rerank eval

Compare Qwen baseline vs Apple Speech vs oracle pick (lower WER wins per clip):

```bash
make eval-apple-speech-rerank ARGS='--limit 50'
```

Results: `benchmark-results/apple-speech-rerank/` (gitignored).

Not wired into the app — benchmark-only.
