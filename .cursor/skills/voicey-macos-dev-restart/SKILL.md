---
name: voicey-macos-dev-restart
description: >-
  Restart Voicey on macOS after rebuilding; check microphone and accessibility;
  reset TCC only when permissions are stale. Use after code changes, make build,
  fixing auto-paste/mic prompts, or when the user wants a clean restart on Mac.
---

# Voicey macOS dev restart

**macOS only** (not Cloud Agent Linux). Run from the repo root in Terminal.app.

## 1. Restart after rebuild (usual case)

```bash
make dev-restart
```

Quits Voicey and Rust workers, rebuilds/signs the direct debug bundle, opens `Voicey.app`.

## 2. Check permissions

Do **not** reset TCC on every rebuild — only when something is actually broken.

| Check | Where |
|-------|--------|
| Microphone | App **Settings** |
| Accessibility (auto-paste) | **Settings → Advanced** |
| System grants | **System Settings → Privacy & Security** |

Direct debug builds use bundle ID `work.voicey.VoiceyDirect` (`make run`, `make dev-restart`). App Store-style debug uses `work.voicey.Voicey`.

Prefer the signed `.app` from `make dev-restart` over `make run-binary` — raw binaries have unreliable TCC behavior.

## 3. Reset permissions (only if needed)

When mic/accessibility prompts are stale, auto-paste fails after rebuild, or the wrong Voicey entry appears in Privacy:

```bash
make reset-permissions-direct-relaunch
```

Accessibility-only: `make accessibility-setup-direct`

App Store-style debug: `make reset-permissions` then `make dev-restart` (or `make run-appstore`).

## Quit without relaunch

```bash
make voicey-quit
```

## Notes

- `tccutil` / `sfltool` need a full macOS terminal (not a restricted sandbox).
- If quit fails: Activity Monitor → quit `Voicey` and `voicey-*`, then retry.
