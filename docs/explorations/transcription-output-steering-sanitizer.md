# Transcription output steering sanitizer (paste-side)

## Status

**Implemented** on `main` in #167 (`75c8142`). Closes [#162](https://github.com/jonathanKingston/voicey/issues/162). Related: #96 (spoken language + decoder steering cleanup), #138 (incremental streaming).

## Problem

Users saw **glossary and screen-context terms in pasted text** when little or no speech was transcribed (beeps, silence, very short clips). Existing filters ran **before** inference (steering selection) or only on in-process `QwenEngine` with a strict prefix echo strip.

## What landed (#167)

Sanitization runs in **`voicey-text` `postprocess`** (mandatory worker — no Swift fallback):

1. **Layer 1 — Echo strip:** `glossary::stripping_echoed_decoder_context` removes verbatim prefix/exact echoes of `decoder_context`.
2. **Layer 2 — Overlap guard:** `glossary::sanitize_steering_echo` clears “screen-term soup” when ≥ 80% of content tokens (minimum 3) match steering vocabulary.

Host passes per-utterance `decoder_context` + `steering_terms` from `TranscriptionSteeringContext` into `PostProcessor.processAsync`. Golden fixtures: `Benchmarks/Golden/postprocess/steering_echo_*.json` (`cargo test -p voicey-text --test golden_postprocess`).

The legacy in-process `QwenEngine` echo strip is retained for live incremental partial overlays; the worker sanitizer is authoritative before paste and is idempotent over already-stripped text.

## Not implemented (optional follow-ups)

- **Low-RMS / short-clip guard** — open a new issue if macOS QA still sees false positives after #167.
- **Rust-only defense-in-depth in infer clients** — not needed while `voicey-text` is mandatory on all paste paths.

## Acceptance criteria (#162)

- [x] Infer + hands-free + manual hotkey paths run output sanitizer before paste (`PostProcessor` → `voicey-text`)
- [x] Linux golden tests (`voicey-text` postprocess fixtures)
- [x] Normal dictation with incidental term overlap not falsely cleared (overlap threshold + minimum token count)

## Non-goals

- Replacing steering input filters (BM25 / `ScreenTermFilter`).
- Hands-free **start clipping** — tracked in [#163](https://github.com/jonathanKingston/voicey/issues/163) / [#169](https://github.com/jonathanKingston/voicey/pull/169).
