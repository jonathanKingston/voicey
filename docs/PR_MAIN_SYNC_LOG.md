# PR main synchronization log

**Date:** 2026-05-29 (cron automation)

**Base:** `main` @ `35e1590` (includes merged #77 infer_ready protocol fix)

## Summary

| PR | Branch | Action |
|----|--------|--------|
| #77 | `fix/infer-ready-protocol-extra-ok` | Merged to main during sync (no branch update needed) |
| #76 | `jkt/auto/m2-stub-workers-integration-bd0c` | Merged main (trailing trim + infer_ready) |
| #57 | `jkt/auto/isolate-whisper-granite-benchmarks-238c` | Merged main; resolved `AppDelegate` conflict (kept Qwen-only path) |
| #55 | `jkt/auto/hands-free-mode-spec-3632` | Merged main; resolved capture trim + `mode` IPC conflicts |
| #66 | `jkt/auto/supervisor-fetch-download-5d25` | Merged main; resolved `voicey-protocol` doc comment conflict |
| #67–#69 | voicey-text → postprocess → benchmark stack | Merged main into each; re-synced stack bases |
| #40, #20, #18, #14 | various `jkt/auto/*` | Merged main |
| — | `fix/infer-ready-protocol-extra-ok` | Already up to date before #77 landed |

## Conflict resolutions

1. **#66** — Combined fetch-worker constants with main’s protocol fixture doc line in `crates/voicey-protocol/src/lib.rs`.
2. **#55** — Rust capture worker: kept hands-free `mode` on `StartRecording` and main’s `apply_trailing_trim` on `StopRecording`. Swift: delegate trim to worker, keep hands-free sample bounding.
3. **#57** — Dropped re-introduced Whisper/Granite engine setup from main in `AppDelegate.setupComponents()` (PR removes those engines from the app path).
