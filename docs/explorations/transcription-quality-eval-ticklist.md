# Transcription quality evaluation ticklist

Tracks experiments for moving dictation quality — especially proper nouns, code terms, and
read-aloud steering — not aggregate LibriSpeech WER alone.

**Primary eval corpus (local):** `benchmark-data/common-voice/prepared/librispeech_clean/test-limit200-seed20260506/` (LibriSpeech dev-clean stand-in; 200 clips).

**Harness:** `make eval-transcription-quality-matrix` → `scripts/eval_transcription_quality_matrix.py`

**Results:** `benchmark-results/quality-matrix/` (gitignored)

---

## How to read status

| Status | Meaning |
|--------|---------|
| ✅ tried | Measured on macOS with recorded results under `benchmark-results/` |
| 🔧 impl | Code landed; eval run pending or partial |
| ⬜ planned | Not implemented yet |
| ❌ skip | Tried or assessed; not worth pursuing now |

---

## A. Evaluation infrastructure

| # | Item | Status | Notes |
|---|------|--------|-------|
| A1 | Raw vs proc WER in Common Voice harness | ✅ tried | 200 clips, qwen3-asr-1.7b-bf16: raw=proc=2.13%, changed=0 (`cv-200-librispeech/`) |
| A2 | Quality matrix runner (multi-variant) | ✅ tried | Smoke 25-clip + full 200-clip run |
| A3 | Term-recall / steering-specific metrics | 🔧 impl | `eval_readaloud_quality_matrix.py`, `eval_readaloud_runtime_matrix.py` |
| A4 | Read-aloud steering corpus on main | ✅ tried | `Benchmarks/readaloud_steering_corpus.json` + harness scripts merged |
| A5 | Session archive replay | 🔧 impl | `scripts/replay_session_archive.py` + `make replay-session-archive` |
| A6 | Fake proper-noun glossary for repair eval | ✅ tried | `eval_proper_noun_glossary.txt` |

---

## B. ASR layer (before cleanup)

| # | Item | Status | Notes |
|---|------|--------|-------|
| B1 | **Model: qwen3-asr-1.7b-bf16** | ✅ tried | 200-clip WER 2.13%, RTF 0.16 |
| B2 | **Model: qwen3-asr-0.6b-6bit** | ✅ tried | 25-clip smoke: 4.47% raw WER vs ~2% for 1.7b |
| B3 | **Language: auto-detect** | ✅ tried | Default benchmark path (no hint passed) |
| B4 | **Language: English hint** | ✅ tried | Smoke: 1.94% vs 1.75% auto (25 clips) |
| B5 | Incremental vs full-buffer | 🔧 impl | Matrix variant `incremental-1.7b-raw`; read-aloud runtime matrix for filename clips |
| B6 | Qwen long-audio chunk merge | ⬜ planned | Seam errors at chunk boundaries |
| B7 | Quiet-audio gain (Granite-style) | ⬜ planned | Port `conditionAudioForInference` to Qwen/infer path |
| B8 | Trailing low-energy trim tuning | ⬜ planned | `AudioCaptureManager` — hands-free vs hotkey |
| B9 | Hands-free VAD vs push-to-talk | ⬜ planned | Needs read-aloud + same mic |
| B10 | Audio stress: quiet (−12 dB) | 🔧 impl | Matrix variant `audio-quiet` |
| B11 | Audio stress: noise bed | 🔧 impl | Matrix variant `audio-noisy` |
| B12 | Decoder steering / glossary at ASR | ✅ tried | Matrix `steer-glossary-*` −0.25 pp WER on 200-clip LibriSpeech |
| B13 | LM Studio vocabulary (post-ASR) | 🔧 impl | Settings + `eval_lm_studio_vocabulary.py` (text goldens; skips if server down) |

---

## C. Post-ASR deterministic (voicey-text)

| # | Item | Status | Notes |
|---|------|--------|-------|
| C1 | Baseline voicey-text (punct, expansions, echo strip) | ✅ tried | Same as proc WER above; 0 clips changed on LibriSpeech |
| C2 | **Fuzzy vocabulary repair** (“spell checker”) | ✅ tried | Smoke: +0.6pp proc WER with broad glossary; use read-aloud next |
| C3 | **NSSpellChecker (macOS)** | ❌ skip for product | AppKit-only; breaks Linux CI parity. Use Rust fuzzy repair instead. |
| C4 | Hunspell custom dictionary | ⬜ planned | Heavier dep; only if fuzzy repair insufficient |
| C5 | **ITN: deterministic rules** | ✅ tried | Smoke: +0.2pp WER on LibriSpeech (expected) |
| C6 | **ITN: small LLM** | ❌ skip for now | Latency + hallucination risk; rules first per below |
| C7 | Expanded text expansions (`mister` → `Mr.`) | ⬜ planned | Overlap with ITN rules |
| C8 | Paste-target format profiles | ⬜ planned | Code vs prose by bundle ID |

### ITN: model vs rules?

**Recommendation: deterministic rules first.**

| Approach | Pros | Cons |
|----------|------|------|
| **Rules** | Fast, CI-golden, no hallucination, offline | Incomplete coverage |
| **LLM (Gemma/LM Studio)** | Flexible | Slow, may rewrite meaning; overlaps LM vocabulary mode |
| **Dedicated ITN model** | SOTA on telephony | Extra model load; not integrated |

Use rules for high-confidence patterns (compounds, `Mr`/`Mrs`, `OK`). Add LLM ITN only for spans rules refuse to touch, with “must not change” golden negatives.

---

## D. Context & steering

| # | Item | Status | Notes |
|---|------|--------|-------|
| D1 | Manual glossary decoder steering | ✅ tried | Matrix `steer-glossary-*` |
| D2 | Screen context BM25 | ⬜ planned | Needs AX snapshot fixtures |
| D3 | Exposure gate (skip steer when AX poor) | ⬜ planned | #150 merged; eval pending |
| D4 | Window title / metadata dictionary | ⬜ planned | Post-process only |
| D5 | OCR fallback (Electron) | ⬜ planned | macOS manual QA |

---

## E. Reranking & ensemble

| # | Item | Status | Notes |
|---|------|--------|-------|
| E1 | Apple Speech offline rerank | ⬜ planned | Apple Speech benchmark package exists |
| E2 | 0.6b vs 1.7b pick by term recall | ⬜ planned | After term-recall metric |
| E3 | Two-pass low-confidence decode | ⬜ planned | Needs confidence from ASR |

---

## F. Product loop

| # | Item | Status | Notes |
|---|------|--------|-------|
| F1 | Session archive + “Mark wrong” | ⬜ planned | Design doc only |
| F2 | Personal dictionary from edits | ⬜ planned | — |
| F3 | Per-app glossary profiles | ⬜ planned | — |

---

## Matrix variants (automation)

| Variant ID | What it tests |
|------------|----------------|
| `baseline-1.7b` | 1.7b, auto language, raw ASR |
| `baseline-1.7b-proc` | 1.7b + default post-process |
| `lang-english-1.7b` | 1.7b + `--language english` |
| `model-0.6b` | 0.6b-6bit raw |
| `audio-quiet-1.7b` | 1.7b on −12 dB clips |
| `audio-noisy-1.7b` | 1.7b on noise-mixed clips |
| `repair-glossary-1.7b` | 1.7b + post-process + vocabulary repair + eval glossary |
| `incremental-1.7b-raw` | 1.7b pause-based incremental batch |
| `steer-glossary-1.7b-*` | 1.7b + decoder glossary steering |

---

## Smoke results (25 clips, 2026-06-17)

| Variant | raw WER | proc WER | changed | Notes |
|---------|--------:|---------:|--------:|-------|
| baseline-1.7b-raw | 1.75% | 1.75% | 0 | Baseline |
| baseline-1.7b-proc | 1.75% | 1.75% | 0 | voicey-text alone does nothing on this corpus |
| lang-english-1.7b-raw | 1.94% | 1.94% | 0 | English hint slightly worse on sample |
| repair-glossary-1.7b | 1.75% | 2.33% | 3 | Fuzzy repair without decoder steer; needs read-aloud eval |
| itn-1.7b | 1.75% | 1.94% | 1 | Expected LibriSpeech mismatch (archaic refs) |

Full 200-clip matrix: `make eval-transcription-quality-matrix ARGS='--limit 200'`.

---

## Next actions

1. Record any pending read-aloud lines (`id_prefix: null` in corpus); run `make eval-readaloud-quality-matrix`.
2. Run `make eval-readaloud-runtime-matrix` on filename clips (batch vs incremental term recall).
3. Run `make replay-session-archive` after bad dictation sessions to validate sanitizer replay.
4. Download **0.6b** (`make benchmark-download-models`) and rerun `model-0.6b-raw`.
5. Run `make eval-lm-studio-vocabulary` when LM Studio is up (optional `--require-server`).
