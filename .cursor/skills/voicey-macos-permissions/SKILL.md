---
name: voicey-macos-permissions
description: >-
  Resets macOS TCC permissions for Voicey (microphone, accessibility, login
  items) so the app can re-prompt or show fresh consent flows. Use when the user
  asks to reset Voicey permissions, re-request Accessibility API access,
  fix auto-paste/accessibility, clear stale TCC entries, or debug permission
  prompts on macOS.
---

# Voicey macOS permissions

Voicey is macOS-only. Bundle identifiers:

| Build | Bundle ID |
|-------|-----------|
| Default / App Store style | `work.voicey.Voicey` |
| Direct distribution | `work.voicey.VoiceyDirect` |

## Reset Accessibility only

Run in **Terminal.app** (or another full macOS terminal). If an agent runs `tccutil` inside a restricted sandbox, it may fail with *Operation not permitted* — rerun outside the sandbox or have the user run the command locally.

```bash
tccutil reset Accessibility work.voicey.Voicey
# Direct build:
tccutil reset Accessibility work.voicey.VoiceyDirect
```

## Reset microphone + accessibility + login items (Makefile)

From the repo root:

```bash
make reset-permissions          # work.voicey.Voicey
make reset-permissions-direct   # work.voicey.VoiceyDirect
```

See also `make accessibility-setup-direct` for the direct-debug accessibility flow (Makefile documents exact steps).

## After resetting

1. **Quit Voicey completely**, then relaunch.
2. Re-grant in **System Settings → Privacy & Security** as needed:
   - **Accessibility** (auto-paste / automation)
   - **Microphone** (if mic was reset)
3. In-app: **Settings → Advanced** shows accessibility status when relevant.

Do not suggest resetting permissions on Linux CI or Cloud Agent VMs; those environments cannot exercise macOS TCC.
