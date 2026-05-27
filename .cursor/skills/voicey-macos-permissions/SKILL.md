---
name: voicey-macos-permissions
description: >-
  Resets macOS TCC permissions for Voicey (microphone, accessibility, login
  items), quits running Voicey/Rust worker processes, and relaunches the app so
  consent prompts appear fresh. Use when the user asks to reset Voicey
  permissions, re-request Accessibility API access, fix auto-paste/accessibility,
  clear stale TCC entries, debug permission prompts, or restart Voicey after a
  permission reset on macOS.
---

# Voicey macOS permissions

Voicey is **macOS-only**. Do not run `tccutil`, `sfltool`, or restart scripts on Linux CI or Cloud Agent VMs.

## Bundle identifiers

| Build | Bundle ID |
|-------|-----------|
| Default / App Store style | `work.voicey.Voicey` |
| Direct distribution | `work.voicey.VoiceyDirect` |

Direct debug builds (`make run`, `make reset-permissions-direct`) use **VoiceyDirect**. App Store-style debug uses **Voicey**.

## Recommended agent workflow

Run from the **repo root** in **Terminal.app** (or another full macOS terminal). If `tccutil` fails with *Operation not permitted*, the command ran in a restricted sandbox — have the user rerun locally or run outside the sandbox.

1. **Quit all Voicey processes** (main app, infer-worker children, and Rust workers):

   ```bash
   ./scripts/voicey_restart.sh --quit-only
   ```

2. **Reset permissions** (pick the row that matches the build under test):

   ```bash
   make reset-permissions          # work.voicey.Voicey
   make reset-permissions-direct   # work.voicey.VoiceyDirect
   ```

3. **Relaunch** so TCC can re-prompt (pick one):

   ```bash
   # Dev: build, sign, and open repo Voicey.app (direct debug — usual default)
   ./scripts/voicey_restart.sh --launch-direct-debug

   # Installed copy in /Applications
   ./scripts/voicey_restart.sh --launch-installed

   # Specific bundle path
   ./scripts/voicey_restart.sh --launch /path/to/Voicey.app
   ```

4. **One-shot Makefile targets** (reset + relaunch for direct debug):

   ```bash
   make reset-permissions-direct-relaunch
   make accessibility-setup-direct   # accessibility only + quit + relaunch + open Settings
   ```

5. Tell the user to re-grant in **System Settings → Privacy & Security** (Microphone, Accessibility) and in-app **Settings → Advanced** for accessibility status.

## What `voicey_restart.sh` stops

| Process | Role |
|---------|------|
| `Voicey` | Main app and `infer-worker` subprocesses (same executable name) |
| `voicey-capture` | Rust mic capture worker |
| `voicey-fetch` | Rust model download worker |
| `voicey-supervisor` | Rust supervisor worker |

Order: AppleScript quit → SIGTERM → wait → SIGKILL. Override wait with `VOICEY_RESTART_WAIT_SECONDS=15` if shutdown is slow.

## Reset Accessibility only

```bash
./scripts/voicey_restart.sh --quit-only
tccutil reset Accessibility work.voicey.Voicey
# Direct build:
tccutil reset Accessibility work.voicey.VoiceyDirect
./scripts/voicey_restart.sh --launch-direct-debug
```

## Reset microphone + accessibility + login items

```bash
make reset-permissions          # work.voicey.Voicey
make reset-permissions-direct   # work.voicey.VoiceyDirect
```

`reset-permissions*` also runs `sfltool resetbtm` for login items (may need admin).

## Troubleshooting

- **Two bundle IDs**: App Store-style and Direct use **separate** instance locks. If both were ever run, quit everything with `./scripts/voicey_restart.sh --quit-only` before resetting the bundle ID you are testing.
- **Stale Accessibility grant**: After rebuilds, prefer a signed `.app` bundle (`--launch-direct-debug` or `make accessibility-setup-direct`) over `make run-binary` — see `Permissions.swift` warnings for raw `.build/debug` binaries.
- **Permission reset without relaunch**: TCC changes often do not apply until the app restarts; always quit and relaunch after `tccutil`.
- **Workers still running**: If quit fails, check Activity Monitor for `Voicey` and `voicey-*`, then rerun the script or `make voicey-quit`.

## Related Makefile targets

| Target | Purpose |
|--------|---------|
| `voicey-quit` | Quit app + workers only |
| `reset-permissions-direct-relaunch` | Reset direct TCC + build/sign/open debug bundle |
| `accessibility-setup-direct` | Reset Accessibility, open Settings, quit, relaunch signed debug bundle |
