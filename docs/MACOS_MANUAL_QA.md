# macOS manual QA checklist

Consolidated gate for hot-path validation that Linux CI cannot exercise (mic, TCC, overlay UX, bundled Rust workers).

**Tracking issue:** [#145](https://github.com/jonathanKingston/voicey/issues/145)

## Setup

```bash
make build-rust && make dev-restart
```

Use default bundled workers (`voicey-capture`, `voicey-fetch`, `voicey-text`, infer). Confirm `voicey-capture` is present in the app bundle.

## PR #138 — `read_captured_samples` incremental streaming

Merge gate for [#138](https://github.com/jonathanKingston/voicey/pull/138) (`voicey-capture` → `IncrementalTranscriptionCoordinator`).

- [ ] **Hotkey dictation:** partial text updates during pause-chunk incremental transcription (bundled `voicey-capture`, not AVFoundation fallback).
- [ ] **Hands-free session:** multi-utterance run with pause-based chunks; partials and final paste match AVFoundation capture behavior.
- [ ] **Regression:** utterance with **no** incremental audio still transcribes from the shared PCM handle (no empty `flushAndFinish`).

**Residual notes (from static review):** when finishing via `flushAndFinish`, trailing trim follows the coordinator heuristic, not Rust `stop_recording` trim; sub-50 ms tail between level poll and stop is acceptable if UX is clean.

## Issue #147 — incremental cancel

Code and Linux unit tests landed in `f56ea29` (PR #148). Exploration record: [`incremental-transcription-cancellation.md`](explorations/incremental-transcription-cancellation.md).

- [ ] Start a **long** incremental partial (pause-chunk transcription in progress).
- [ ] Press **Escape** (or stop/cancel per product flow).
- [ ] Overlay returns to **idle** promptly.
- [ ] **No late partial text** appears after cancel.

## PR #150 — screen-context capture before steering

When [#150](https://github.com/jonathanKingston/voicey/pull/150) is merged; can be combined with the #138 pass.

- [ ] Screen context **enabled**; dictate immediately after record start.
- [ ] Logs show `ready` or `timeout` for capture wait (not silent empty steering).
- [ ] With incremental chunks: screen terms apply on **first and later** pause chunks (see [`screen-context-incremental-reuse.md`](explorations/screen-context-incremental-reuse.md)).

## Model session lifecycle

From [`model-session-lifecycle-races.md`](explorations/model-session-lifecycle-races.md) (implemented on `main`; Linux tests green).

- [ ] Start recording, trigger a model change from Settings — clear user feedback (no silent reset).
- [ ] Pending model upgrade cannot overlap rapid hotkey start/stop.

## Screen context incremental reuse

From [`screen-context-incremental-reuse.md`](explorations/screen-context-incremental-reuse.md) (implemented on `main`).

- [ ] Dictate a term visible in the active window **before and after** a pause within one recording; steering applies consistently on both chunks.

## Sign-off

When all sections needed for the current merge are checked, comment on [#145](https://github.com/jonathanKingston/voicey/issues/145) with build/commit, scenarios run, and pass/fail. Close [#147](https://github.com/jonathanKingston/voicey/issues/147) after the cancel row above passes.
