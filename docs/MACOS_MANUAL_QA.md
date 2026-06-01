# macOS manual QA checklist

Consolidated gate for hot-path validation that Linux CI cannot exercise (mic, TCC, overlay UX, bundled Rust workers).

**Tracking issue:** [#145](https://github.com/jonathanKingston/voicey/issues/145) (closed Jun 2026 — checklist retained for regressions and open PRs)

## Setup

```bash
make build-rust && make dev-restart
```

Use default bundled workers (`voicey-capture`, `voicey-fetch`, `voicey-text`, infer). Confirm `voicey-capture` is present in the app bundle.

## Rust capture incremental streaming (`main`, #138 + #166)

On `main` since #138; [#166](https://github.com/jonathanKingston/voicey/pull/166) fixes `read_samples_since` / `sample_count` consistency (no silent PCM skip between polls).

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

Paste this template on [#145](https://github.com/jonathanKingston/voicey/issues/145) (edit sections and checkboxes as needed):

```markdown
## macOS manual QA sign-off

- **Commit / build:** `$(git rev-parse HEAD)` after `make build-rust && make dev-restart`
- **PRs exercised:** #150 (screen-context gate) / #167 (paste sanitizer) / #169 (hands-free finish) / `main` only — delete unused rows
- **Scenarios:** hotkey incremental partials; hands-free multi-utterance; Escape cancel (#147); screen-context wait logs (#150); model-change during record (if on `main`)
- **Result:** pass | fail
- **Notes:** (failures, env, residual trim behavior)
```
