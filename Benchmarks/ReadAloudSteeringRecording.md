# Read-aloud steering recording script (corpus v3)

## Recording checklist (macOS)

Use this before running `make eval-readaloud-quality-matrix`.

- [ ] **Build:** `make build build-rust`
- [ ] **Models:** Qwen 1.7b downloaded (`make benchmark-download-models`)
- [ ] **Dictation history:** Settings → enable **Keep dictation history locally** (or `VOICEY_SESSION_ARCHIVE=1`)
- [ ] **Glossary:** paste the blended list below into Settings → Transcription (optional for live; replay injects it)
- [ ] **Mic + Speech:** Voicey has microphone access; Terminal/Cursor has Speech Recognition if you use Apple Speech rerank
- [ ] **Session Archive path exists:** `~/Library/Application Support/Voicey/SessionArchive/`
- [ ] **Record:** one clip per script line (#1–#27) — stop, wait for history, next line ([table below](#what-to-read-in-order))
- [ ] **Map ids:** `python3 scripts/map_readaloud_archive_ids.py --write-corpus` (or paste `id_prefix` by hand)
- [ ] **Export backup bundle:** `make export-readaloud-artifact`
- [ ] **Run evals:**
  - ASR + steering replay: `make eval-readaloud-steering`
  - Delivery / sanitizer: `make eval-readaloud-delivery-matrix`
  - Term recall summary: `make eval-readaloud-quality-matrix`

---

## What eval needs (live paste optional)

| For scoring | Source |
|-------------|--------|
| **Audio** | Session Archive `audio/*.wav` (via `id_prefix`) |
| **Expected words** | [`readaloud_steering_corpus.json`](readaloud_steering_corpus.json) `reference` per line |

**Live `processed_text` and clipboard paste are not used for ASR eval.** The harness re-transcribes each WAV and compares to `reference`.

Archive metadata (`raw_text`, `outcome`, `empty_delivery`) is useful for the **delivery matrix** (`make eval-readaloud-delivery-matrix`), which replays post-process with the archived steering snapshot and checks whether anything would be deliverable.

---

## Backup bundle (zip this; not in git)

```bash
make export-readaloud-artifact
# optional dated copy:
make export-readaloud-artifact ARGS="--tag 2026-06-18"
```

**Directory to zip:**

`~/Library/Application Support/Voicey/Artifacts/readaloud-corpus-v3/`

Contains:

- `audio/` — WAV per line  
- `snapshots/` — screen context JSON (when recorded)  
- `index.jsonl` — archive rows for those clips  
- `corpus_manifest.json` — copy of this corpus (`reference` = ground truth)  
- `ARTIFACT.json` — export metadata and replay commands  

Override install location with `VOICEY_ARTIFACTS_ROOT`.

Replay from the bundle on another machine:

```bash
make eval-readaloud-steering ARGS='--archive-root "$HOME/Library/Application Support/Voicey/Artifacts/readaloud-corpus-v3"'
make eval-readaloud-delivery-matrix ARGS='--archive-root "$HOME/Library/Application Support/Voicey/Artifacts/readaloud-corpus-v3"'
```

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

1. Update `id_prefix` in the corpus JSON if needed (`map_readaloud_archive_ids.py --write-corpus`).
2. `make export-readaloud-artifact` then zip `~/Library/Application Support/Voicey/Artifacts/readaloud-corpus-v3/`.
3. Run evals (results under `benchmark-results/`, gitignored):

   ```bash
   make eval-readaloud-steering
   make eval-readaloud-delivery-matrix
   make eval-readaloud-quality-matrix
   ```

Do not commit Session Archive audio, artifact bundles, or result JSON.
