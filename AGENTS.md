# Agent Guidelines for Voicey

This document helps AI agents understand and work with this codebase effectively.

## Project Overview

Voicey is a macOS menubar app for voice-to-text transcription using WhisperKit. It runs locally on-device with no cloud dependencies.

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
