# Transcription output steering sanitizer (paste-side)

## Status

Exploration — follow-up after #138 merge. Related: #96 (spoken language + stronger echo strip), hands-free steering soup repro (“beep, beep” → pasted term list).

## Problem

Users see **glossary and screen-context terms in pasted text** when little or no speech was transcribed (beeps, silence, very short clips). Existing filters mostly run **before** inference (steering selection) or on **Whisper segmented** post-process paths. The default **Qwen infer worker** path returns trimmed `raw_text` with **no** `strippingEchoedDecoderContext`.

## What we already have (and why paste still leaks)

| Mechanism | Stage | Qwen infer hot path |
|-----------|--------|---------------------|
| `ScreenTermFilter` / BM25 selection | Input steering | Reduces junk **into** context; does not scrub **output** |
| `TranscriptionGlossary.strippingEchoedDecoderContext` | After decode | **In-process `QwenEngine` only**; prefix must match **full** `decoder_context` |
| `NoiseFilter` / `PostProcessBuilder.filterNoise` | After decode | **Skipped** when `segments` empty (Qwen) |
| Granite low-RMS empty guard | Before decode | **Not** on Qwen infer |

Incremental transcription (#138) increases partial decode passes; steering regurgitation can be **joined** across chunks before paste.

## Proposed paste-side pipeline (ordered)

Apply on the host **after** infer returns `TranscriptionResult.text`, **before** `PostProcessor` (so voice commands still run on cleaned speech). Use the **same** `decoder_context` string (or term list) that was sent for that utterance (`TranscriptionSessionModelPin` + snapshot of steering at utterance start).

### Layer 1 — Echo strip (parity)

- Call `TranscriptionGlossary.strippingEchoedDecoderContext(text, decoderContext:)` on **every** Qwen result (infer worker, supervisor, in-process, incremental chunk merge).
- Extend strip to handle legacy `Spelling:` prefix (#96 direction).
- **Does not fix** comma-separated term soup that is not a prefix of full context.

### Layer 2 — Steering term overlap guard

When glossary and/or screen steering was enabled for the utterance:

1. Build `steeringTerms: Set<String>` from terms in `decoder_context` (parse `Glossary:` list + screen terms if tracked separately).
2. Tokenize output (same rules as screen filter or simple word split).
3. If **fraction of tokens** that appear in `steeringTerms` exceeds a threshold (e.g. ≥ 0.6) **and** token count ≥ N (e.g. ≥ 8), treat as **steering hallucination** → empty string (do not paste).
4. Optional softer mode: drop only tokens in `steeringTerms` and keep remainder if remainder has deliverable content.

Golden tests in `VoiceyCore` + shared JSON under `Benchmarks/Golden/` if we add Rust parity in `voicey-text`.

### Layer 3 — Low-speech / low-RMS guard (optional)

Before paste (or before infer for tiny clips):

- If captured duration &lt; 0.5s **or** RMS below floor (reuse incremental / Granite constants), skip paste unless transcript passes a strict “looks like user speech” check.
- Avoid blocking legitimate short commands (“stop”, “yes”) via minimum token rules or allowlist.

### Layer 4 — Incremental-specific

- After `combinedTextLocked()` / `flushAndFinish`, run Layer 1–2 once on **final** text (not only per chunk).
- Consider skipping incremental chunks when sealed audio RMS &lt; threshold (reduce beep-triggered chunk ASR).

## Implementation sketch

| Piece | Location |
|-------|----------|
| `TranscriptionOutputSanitizer` (pure functions) | `Sources/VoiceyCore/` |
| Pass `decoderContext` + flags into sanitizer | `AppDelegate` (`handleTranscriptionResult`, hands-free deliver path, incremental coordinator callback if exposing partials) |
| Infer clients | Optionally strip in `VoiceyRustSupervisorClient` / `QwenInferWorkerClient` for defense in depth |
| Rust parity | `voicey-text` module + golden fixtures (#134–#137 pattern) |

## Acceptance criteria

- [ ] “beep, beep” hands-free with screen context + glossary enabled → **no paste** (or empty), not term soup.
- [ ] Normal sentence with incidental overlap (e.g. user says “Cursor”) → **not** falsely cleared.
- [ ] Linux unit tests for sanitizer; no macOS requirement.
- [ ] Incremental + non-incremental paths share one sanitizer entry point.

## Non-goals

- Replacing steering input filters (keep BM25 / `ScreenTermFilter`).
- Solving hands-free **start clipping** (separate issue — finish route vs PCM drain).
