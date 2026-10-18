# Agent Guidelines for Voicey

This document helps AI agents understand and work with this codebase effectively.

## Project Overview

Voicey is a macOS menubar app for voice-to-text transcription. It is Qwen-first, using native Swift MLX inference (WhisperKit and Granite backends are retained only for benchmarking and runtime parity). It runs locally on-device with no cloud dependencies.

## Key Files for Understanding the Codebase

| File | Purpose |
|------|---------|
| `Package.swift` | Dependencies and build configuration |
| `Sources/Voicey/App/AppDelegate.swift` | Main app lifecycle and hotkey handling |
| `Sources/Voicey/App/AppState.swift` | Shared application state |
| `Sources/Voicey/App/Dependencies.swift` | Dependency injection container |
| `Makefile` | Build commands (`make build`, `make run`, `make clean`) |

## Coding Standards

**Read the Swift coding guidelines before making changes:**

→ [`.cursor/rules/swift-guidelines.mdc`](.cursor/rules/swift-guidelines.mdc)

This file contains:
- Memory management patterns (event monitors, timers)
- Thread safety guidelines
- Swift concurrency best practices
- Error handling requirements
- Logging conventions
- Architecture patterns (DI, state management)
- Pre-commit checklist

## Running Static Analysis

```bash
# Install SwiftLint if needed
brew install swiftlint

# Run linter
swiftlint

# Auto-fix issues
swiftlint --fix
```

## Building and Testing

```bash
# Build the app
make build

# Run the app
make run

# Clean build artifacts
make clean

# Build release version
make release
```

## Direct macOS releases (agent runbook)

Use `make ship-release VERSION=X.Y.Z` for a signed, notarized GitHub release. `make release` only builds the app. Read [`scripts/release.sh`](scripts/release.sh) and the relevant Makefile targets first; [`SPARKLE_CI.md`](SPARKLE_CI.md) describes Sparkle concepts but contains illustrative CI steps, not a substitute for the local release script.

### Lessons from the v1.7.0 session

- Model prewarming shipped in #238; #239 fixed the release script to sign the bundled `voicey-text` worker before notarization. The release version commit is `00784da`.
- Preparing the Mac toolchain and release credentials took several attempts. Check all prerequisites before starting the expensive clean build.
- The website checkout was identified as `/Users/jonathankingston/debugging/voicey.work`. The script instead assumes `../Voicey.work/public/appcast.xml`; this relative path is especially unreliable from an isolated worktree.
- The existing Sparkle key was supplied through `.env.release`, but the script's bare `sign_update` invocation looks in Keychain. Loading that environment file alone does not make `SPARKLE_PRIVATE_KEY` available to the signer.
- GitHub downloads and the website appcast are separate publication steps. A successful upload, or the script's final success message, does not prove automatic updates are live.

### Preflight before building

1. Confirm the requested version, source commit, and checkout. The script requires `main` with no tracked changes or untracked files. Inspect unexpected files (including generated `Package.resolved`) and preserve unrelated work; do not delete or commit them merely to satisfy this check. Check whether the version's tag/release already exists before rerunning.
2. On macOS, check the selected full Xcode installation (`xcode-select -p`, `xcrun swift --version`) and that Metal, `notarytool`, and `stapler` are available. Check Rust/Cargo against [`rust-toolchain.toml`](rust-toolchain.toml) (currently 1.86.0), plus `make`, `python3`, `curl`, `gh`, `codesign`, `ditto`, and `hdiutil`. Confirm GitHub authentication and repository access. Report missing components together.
3. The script loads the ignored `.env.release` from the checkout root. Required local names are `DEVELOPER_ID`, `APPLE_ID`, `TEAM_ID`, and `APP_PASSWORD`; CI documentation uses different names for some of these. Confirm the Developer ID Application certificate has its private key and is usable for signing, and that notarization credentials are configured.
4. Resolve direct-distribution dependencies with `VOICEY_DIRECT=1 swift package resolve` when needed; Sparkle tools live in `.build/artifacts/sparkle/Sparkle/bin`. Confirm the existing update-signing key is usable **before** the build. The Apple signing certificate, Apple app-specific password, and Sparkle EdDSA key are separate credentials.
5. Check the actual website checkout and `public/appcast.xml` before publishing. The path above is this maintainer's known checkout, not a portable default. Inspect its status and deployment workflow, and arrange approved access if it is outside the workspace.
6. Keep credentials out of chat, diffs, shell tracing, and logs. Let the release tooling consume configured secrets without displaying credential files. Ask the user to update them locally when necessary. Use Copse tools and their approval path for host/network operations; do not work around a denied operation.

### Sparkle key recovery

- Reuse the private key matching `SUPublicEDKey` in `Info.direct.plist` and already distributed apps. Do not generate replacement keys or change the public key to get a release through.
- If the key is on the previous release Mac, the owner can export the existing key privately using Sparkle's `generate_keys` tool. `make sparkle-export-private-key` prints the private key, so agents must not capture its output in the conversation.
- For an exported key in `.env.release`, inspect the installed `sign_update --help` and use its supported private-key input, or have the owner import the existing key with `generate_keys`. Do not assume an environment variable is automatically consumed.
- A format/base64 error is not proof the original key is wrong. Check the installed tool's expected export format and local quoting/encoding without revealing the key; verify the derived public key matches `SUPublicEDKey`. Keep any temporary key material private and remove it after use.

### Build, publish, and finish

1. Run `make ship-release VERSION=X.Y.Z` from the verified checkout. It bumps `Info.plist`, `Info.direct.plist`, and `project.yml`; builds the direct app and Rust workers; signs inside out; notarizes/staples the app; creates ZIP/DMG assets; notarizes/staples the DMG; then commits the version, tags, and publishes to GitHub.
2. All bundled executables must be signed, including `voicey-capture`, `voicey-fetch`, `voicey-supervisor`, and `voicey-text`, plus Sparkle components and `mlx.metallib`. Preserve Metal signature xattrs: the DMG workaround removes only `com.apple.provenance`, not every extended attribute. `SKIP_DMG=1` produces a ZIP-only release; use it only when that reduced output is agreed.
3. Retain bounded build/notarization logs and exit status. For long jobs, use a bounded background task with completion notification. On failure, inspect the saved log and completed stages before retrying.
4. After GitHub publication, download the **published ZIP** and generate its Sparkle signature and byte length. Use those exact bytes for the appcast; rebuilding or recompressing locally can change them. Update only the intended version item and preserve older entries.
5. Commit/push the website appcast change when authorized and verify deployment. The current script only edits the assumed local appcast and prints a reminder; it does not publish the website. It also does not wire `SPARKLE_PRIVATE_KEY` into `sign_update`. Account for both gaps explicitly.
6. Verify the GitHub release is published with the expected tag and assets, signatures/notarization pass, and the live feed at the app's `SUFeedURL` contains the correct version, download URL, length, and EdDSA signature. Distinguish these checks from an actual update test in an older installed app; report any unverified step.

### Resume instead of restarting

If a late step fails, inspect the existing version commit, tag target, GitHub release/assets, and website state first. A rerun of the script starts with a clean build; an existing GitHub release causes asset publication to be skipped, and an existing tag must point at HEAD. Resume signing/appcast/deployment from the published ZIP when those are the only remaining steps. Do not move a published tag or replace released assets without explicit authorization. Report GitHub publication and live automatic-update status separately.

## Architecture Notes

### Dependency Injection

The app uses protocol-based DI via `Dependencies.swift`. When adding new managers:

1. Define a protocol (e.g., `FooProviding`)
2. Make the manager conform to it
3. Add to `Dependencies` container
4. Inject via initializer for testability

### State Management

`AppState` is the single source of truth for UI state. `TranscriptionState` enum uses associated values:

- `.idle` - Ready for recording
- `.recording(startTime:)` - Currently capturing audio
- `.processing` - Transcribing audio
- `.completed(text:)` - Transcription finished
- `.error(message:)` - Something went wrong

### Concurrency Model

- Use `Task { @MainActor in ... }` for UI updates
- Audio processing uses `DispatchQueue` with barriers for thread safety
- Avoid mixing old GCD patterns with new Swift concurrency

## Common Pitfalls

These issues were found during code review. Avoid repeating them:

1. **Event monitor leaks** - Always store and remove monitors
2. **TOCTOU races** - Make state checks and actions atomic
3. **Silent error swallowing** - Don't use `try?` without handling
4. **Stale settings** - Use computed properties for dynamic config
5. **Dead code** - Remove unused files and code paths

## Code Review History

See [`CODE_REVIEW.md`](CODE_REVIEW.md) for the full history of issues found and fixed. This provides context on past problems and their solutions.

## Cursor Cloud specific instructions

### Platform constraint

Voicey is a **macOS-only** application. The Cloud Agent VM runs Linux, so `swift build` / `make build` / `make run` will fail with missing Apple framework errors (SwiftUI, AppKit, AVFoundation, CoreML, Metal, etc.). This is expected and not a bug.

### What works on Linux

| Task | Command | Notes |
|------|---------|-------|
| Dependency resolution | `swift package resolve` | Fetches all SPM dependencies successfully |
| Linting | `swiftlint lint Sources/` | Runs against project source files |
| Formatting | `swift-format -i -r Sources/` | Bundled with the Swift toolchain |
| Syntax/logic review | Manual code inspection | Review Swift files directly for correctness |

### What does NOT work on Linux

- `swift build` — fails at Apple-only framework imports (SwiftUI, AppKit, CoreML, etc.)
- `make build` / `make run` / `make bundle` — all depend on `swift build` succeeding
- Any target that requires `codesign`, `xcodegen`, `productbuild`, or macOS system tools

### Developing in Cloud Agent

When making code changes on this codebase from a Cloud Agent:

1. Run `swiftlint lint Sources/` to validate style/lint rules after changes.
2. Run `swift-format -i -r Sources/` if formatting is needed (or `make format`).
3. Compilation and runtime testing must happen on a macOS machine. The Cloud Agent cannot verify builds.
4. The Swift toolchain is at `/opt/swift/usr/bin`. It is added to `PATH` via `~/.bashrc`.
5. SwiftLint is installed at `/usr/local/bin/swiftlint` (v0.58.2, Linux x86_64 binary).
6. `libstdc++-14-dev` must be installed for SPM dependency resolution to compile C++ dependencies (BoringSSL in swift-crypto).

### Rust sandboxed runtime (macOS)

See [`docs/RUST_RUNTIME.md`](docs/RUST_RUNTIME.md). Build workers with `make build-rust` (requires Rust toolchain on macOS). Qwen uses the infer worker by default; set `VOICEY_RUNTIME=in-process` to force in-app MLX. Runtime parity: `make benchmark-runtime-parity-common-voice`, `make benchmark-measure-runtime-memory`.

### macOS dev restart (agents on Mac)

After rebuilds or permission issues on a **Mac** (not Cloud Linux), use [`.cursor/skills/voicey-macos-dev-restart/SKILL.md`](.cursor/skills/voicey-macos-dev-restart/SKILL.md): `make dev-restart` by default; `make reset-permissions-direct-relaunch` only when TCC is stale.

### Implementation priority (agents)

Canonical status: [`docs/ISSUE_74_PROGRESS.md`](docs/ISSUE_74_PROGRESS.md).

| Priority | Work | Cloud Agent? |
|----------|------|----------------|
| 1 | Review/merge open PRs [#150](https://github.com/jonathanKingston/voicey/pull/150) (screen-context gate), [#169](https://github.com/jonathanKingston/voicey/pull/169) (#163 hands-free finish) — macOS spot-check per [`docs/MACOS_MANUAL_QA.md`](docs/MACOS_MANUAL_QA.md) | No (macOS only) |
| 2 | Do **not** open duplicate PRs for screen-context capture gate (#150) or hands-free PCM finish (#169) | — |
| 3 | After #150 merge: [#152](https://github.com/jonathanKingston/voicey/issues/152) / [#70](https://github.com/jonathanKingston/voicey/issues/70) Phase 2+ — delete remaining Swift hot-path fallbacks (`AVAudioEngine`, Hub fetch); text/post-process layer done in #167 | Partial (Linux tests/docs; capture/fetch removal needs macOS spot-check) |

Incremental cancel ([#147](https://github.com/jonathanKingston/voicey/issues/147)) is implemented on `main`; only the Escape/cancel row in the macOS checklist remains.
