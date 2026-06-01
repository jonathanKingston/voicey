# Transcription output steering sanitizer (paste-side)

## Status

**Implemented** on `main` in #167 (`75c8142`). Closes [#162](https://github.com/jonathanKingston/voicey/issues/162). Related: #96 (spoken language + decoder steering cleanup), #138 (incremental streaming).

## Problem

Users saw **glossary and screen-context terms in pasted text** when little or no speech was transcribed (beeps, silence, very short clips). Existing filters ran **before** inference (steering selection) or only on in-process `QwenEngine` with a strict prefix echo strip.

## What landed (#167)

Sanitization runs in **`voicey-text` `postprocess`** (mandatory worker — no Swift fallback):

1. **Prefix / exact substring** of `decoder_context`
2. **Comma-list filter** — long comma-separated segments that are steering-only (typical screen dump without the vocabulary prefix)
3. **Embedded `Vocabulary:` / legacy `Glossary:` run** removal between speech
4. **Soup** — ≥80% steering tokens clears the utterance
5. **Polish** — seam punctuation cleanup

Host passes per-utterance `decoder_context` + `steering_terms` from `TranscriptionSteeringContext` into `PostProcessor.processAsync`. Golden fixtures: `Benchmarks/Golden/postprocess/steering_echo_*.json` (`cargo test -p voicey-text --test golden_postprocess`).

The in-process `QwenEngine` echo strip was removed in #167: `transcribeSinglePass` now returns the raw model output verbatim (see `QwenEngine.swift` — "Steering echo stripping happens later in the text post-process pipeline"). The `voicey-text` worker sanitizer is the sole authoritative path before paste and is idempotent over already-stripped text. Live incremental partial overlays may therefore still surface steering echoes briefly; only the final post-processed paste is guaranteed clean.

## Not implemented (optional follow-ups)

- **Low-RMS / short-clip guard** — open a new issue if macOS QA still sees false positives after embedded-run stripping.
- **Rust-only defense-in-depth in infer clients** — not needed while `voicey-text` is mandatory on all paste paths.

## Acceptance criteria (#162)

- [x] Infer + hands-free + manual hotkey paths run output sanitizer before paste (`PostProcessor` → `voicey-text`)
- [x] Linux golden tests (`voicey-text` postprocess fixtures)
- [x] Normal dictation with incidental term overlap not falsely cleared (overlap threshold + minimum token count)

## Non-goals

- Replacing steering input filters (BM25 / `ScreenTermFilter`).
- Hands-free **start clipping** — tracked in [#163](https://github.com/jonathanKingston/voicey/issues/163) / [#169](https://github.com/jonathanKingston/voicey/pull/169).
