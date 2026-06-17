# Read-aloud steering recording script (corpus v3)

## Recording checklist (macOS)

Use this before running `make eval-readaloud-quality-matrix`.

- [ ] **Build:** `make build build-rust`
- [ ] **Models:** Qwen 1.7b downloaded (`make benchmark-download-models`)
- [ ] **Glossary:** paste the blended list below into Settings → Transcription (optional for live; replay injects it)
- [ ] **Mic + Speech:** Voicey has microphone access; Terminal/Cursor has Speech Recognition if you use Apple Speech rerank
- [ ] **Session Archive path exists:** `~/Library/Application Support/Voicey/SessionArchive/`
- [ ] **Record:** one clip per script line (#1–#27) — stop, wait for history, next line ([table below](#what-to-read-in-order))
- [ ] **Map ids:** each new utterance gets an 8-char id in Dictation history — paste into [`readaloud_steering_corpus.json`](readaloud_steering_corpus.json) `id_prefix` if re-recording
- [ ] **Verify local WAVs:** `make eval-readaloud-steering` (fails fast if Session Archive clips are missing)
- [ ] **Run evals:**
  - Term recall: `make eval-readaloud-quality-matrix`
  - Runtime (batch vs incremental): `make eval-readaloud-runtime-matrix`
  - Broad analysis: `make benchmark-broad-steering-analysis`

Corpus v3 already has `id_prefix` for #1–#27 from the 2026-06-02 session. Re-record only if you need fresh audio or changed Settings.

---

## Manual glossary (paste into Settings → Transcription)

Use this **blended** list (Voicey project terms + synthetic OOV + domain tokens):

```text
IncrementalTranscriptionCoordinator.swift, Voicey, Qwen, voicey-text, UtteranceTranscriptionFinish.swift, Klorp-9-alpha, ZorbnaxWorker, xyzzy-protocol, metformin, HbA1c
```

Screen context: **your choice** (off = simpler live vs replay; on = extra soup for combo replay later).

## What to read (in order)

| # | Read exactly | Why |
|---|----------------|-----|
| **1** | Hello. | Warmup |
| **2** | Beep. Boop. | Warmup / short clip |
| **3** | The quick brown fox jumps over the lazy dog. | Warmup / phonetic spread |
| **4** | Incremental Transcription Coordinator dot swift. | Bare filename phrase (regurgitation canary) |
| **5** | This file is Incremental Transcription Coordinator dot swift. | Sentence + coordinator symbol |
| **6** | The coordinator lives in Incremental Transcription Coordinator dot swift. | Same template, regression |
| **7** | Open Incremental Transcription Coordinator dot swift in the editor. | Sentence; often stays spoken “dot swift” |
| **8** | Open Utterance Transcription Finish dot swift. | **Second** Swift symbol (not coordinator) |
| **9** | The worker is voicey-text. | Hyphenated crate name |
| **10** | Voicey uses Qwen and the voicey-text worker. | Brand / homophone (Voici, Quen) |
| **11** | What more can we do here that improves the quality? | Natural / no identifier |
| **12** | Check out the existing data and translations, then run it against the benchmarking code. | Long natural |
| **13** | Ship the pull request when CI is green. | Natural |
| **14** | I like incremental progress on this project. | False positive (“incremental” ≠ filename) |
| **15** | The coordinator team met yesterday. | False positive (“coordinator” ≠ file) |
| **16** | This function is process hands free incremental utterance. | Code-ish spoken |
| **17** | Refactor incremental transcription coordinator. | Code-ish spoken |
| **18** | The service is named Klorp nine dash alpha. | **OOV** sentence (glossary: `Klorp-9-alpha`) |
| **19** | Klorp nine dash alpha. | **OOV** bare phrase (regurge canary) |
| **20** | We run ZorbnaxWorker next to the xyzzy-protocol crate. | Synthetic worker + crate |
| **21** | Open Utterance Transcription Finish dot swift in Xcode. | Alt filename in full sentence |
| **22** | The patient metformin dose increased and HbA1c improved. | Domain vocab (medical golden-style) |
| **23** | My ideal vacation is Kuala Lumpur because it is warm every day. | Proper noun (no glossary entry) |
| **24** | Refactor the Zorbnax worker module before release. | Partial OOV (“Zorbnax” vs `ZorbnaxWorker`) |
| **25** | The qwen three ASR one point seven b model loads locally. | Spoken model id → `Qwen` bias |
| **26** | Paste into voicey text pre post process without screen content. | Crate name in prose (you misspoke “pre/post” and “content”; reference matches what you read) |
| **27** | Tell me about your favorite food and how often you cook at home. | CV-like spontaneous control |

## After recording

1. Update `id_prefix` in `Benchmarks/readaloud_steering_corpus.json` for new rows.
2. Broad analysis (read-aloud + Common Voice, same blended glossary):

   ```bash
   make benchmark-broad-steering-analysis
   ```

   Or read-aloud only:

   ```bash
   python3 scripts/eval_readaloud_artificial_steering.py
   ```

Results live under `benchmark-results/` (gitignored). Do not commit Session Archive audio or result JSON.
