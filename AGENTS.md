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
