# Apple SpeechAnalyzer eval harness

Standalone benchmark CLI for comparing Apple's **SpeechAnalyzer** / **SpeechTranscriber**
against Voicey's Qwen and legacy benchmark backends.

This package is intentionally **outside** the main `Voicey` SwiftPM target so
`make build` on macOS 15 CI keeps compiling until the project adopts the macOS 26 SDK.

## Requirements

- macOS **26** or later
- Xcode with the **macOS 26 SDK** (SpeechAnalyzer symbols)
- Network on first run per locale (Speech `AssetInventory` model download)

## Build

```bash
make build-apple-speech-benchmark
```

Binary: `Benchmarks/AppleSpeech/.build/debug/voicey-apple-speech-benchmark`

## Single-file smoke test

```bash
Benchmarks/AppleSpeech/.build/debug/voicey-apple-speech-benchmark \
  --audio /path/to/clip.mp3 \
  --locale en-US \
  --json
```

Optional glossary steering eval (maps to `AnalysisContext.contextualStrings`):

```bash
Benchmarks/AppleSpeech/.build/debug/voicey-apple-speech-benchmark \
  --audio /path/to/clip.mp3 \
  --context "NSNotificationCenter,SwiftUI,ViewModel" \
  --json
```

## Common Voice comparison (side-by-side with Qwen)

Prepare the deterministic Common Voice slice, build both stacks, then run:

```bash
make benchmark-run-apple-speech-common-voice
```

Compare Apple Speech **and** Qwen in one pass:

```bash
make benchmark-common-voice ARGS='\
  --tsv benchmark-data/common-voice/prepared/.../test.tsv \
  --clips-dir benchmark-data/common-voice/prepared/.../clips \
  --voicey-model qwen3-asr-1.7b-bf16 \
  --apple-speech \
  --measure-duration'
```

Or use the convenience target that includes Qwen by default:

```bash
make benchmark-run-apple-speech-vs-qwen-common-voice
```

Results land in `benchmark-results/` as JSONL + summary JSON + examples markdown,
matching the existing Common Voice harness format.

## Presets

| CLI `--preset` | SpeechTranscriber preset | Use |
|---|---|---|
| `offline` (default) | `.offlineTranscription` | WER/RTF parity with batch Qwen |
| `live` | `.progressiveLiveTranscription` | Volatile/live path smoke |

## Notes

- Apple inference runs **out of process**; RTF from `--json` excludes first-clip asset download unless `--warmup` covers it.
- Empty transcripts fail the CLI (exit 1); use `--keep-going` on the Python harness to record failures.
- This harness does **not** exercise Voicey glossary BM25 / screen-context steering — only Apple's `contextualStrings` API.
