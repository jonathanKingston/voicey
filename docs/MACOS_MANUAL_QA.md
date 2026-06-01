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

Code and Linux unit tests landed in `f56ea29` (PR #148); [#147](https://github.com/jonathanKingston/voicey/issues/147) is **closed**. Exploration record: [`incremental-transcription-cancellation.md`](explorations/incremental-transcription-cancellation.md). The macOS rows below remain for sign-off (often combined with #150 / #169 QA).

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

## Issue #162 / PR #167 — steering-echo sanitizer

Implemented on `main` (`75c8142`); sanitization runs in bundled `voicey-text` before paste.

- [ ] **Hands-free beep/silence:** with glossary + screen context enabled, frontmost window with rich text; short beeps or near-silence through utterance end → **no pasted term soup** (empty or real speech only).
- [ ] **Normal dictation:** say a sentence that incidentally mentions a biased screen term (e.g. “open Cursor”) → transcript **not** falsely cleared.
- [ ] **Incremental partials:** live overlay partials may still show steering echoes briefly; **final paste** after post-process should be clean.

## Sign-off

When all sections needed for the current merge are checked, comment on [#145](https://github.com/jonathanKingston/voicey/issues/145) with build/commit, scenarios run, and pass/fail (include the #147 cancel rows when exercised).

Paste this template on [#145](https://github.com/jonathanKingston/voicey/issues/145) (edit sections and checkboxes as needed):

```markdown
## macOS manual QA sign-off

- **Commit / build:** `$(git rev-parse HEAD)` after `make build-rust && make dev-restart`
- **PRs exercised:** #150 (screen-context gate) / #169 (#163 hands-free finish) / #167 (#162 steering sanitizer) / `main` only — delete unused rows
- **Scenarios:** hotkey incremental partials; hands-free multi-utterance + back-to-back utterance 2 (#163); Escape cancel (#147); screen-context wait logs (#150); steering-echo beep repro (#167); model-change during record (if on `main`)
- **Result:** pass | fail
- **Notes:** (failures, env, residual trim behavior)
```
