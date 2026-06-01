# Issue #74 — Rust CI testability progress

Tracking issue: [GitHub #74](https://github.com/jonathanKingston/voicey/issues/74)

This file mirrors the milestone checklist on the GitHub issue so agents and contributors can see status in-repo. Update both when milestones land.

## Milestones

### M1 — Contract tests (protocol is source of truth)

- [x] Golden JSON fixtures for every protocol variant (`crates/voicey-protocol`, `make protocol-fixtures`)
- [x] CI round-trip + reject-unknown-field tests
- [x] Swift `VoiceyProtocolFixtureTests` decodes same fixtures
- [x] Protocol change process in [`RUST_PROTOCOL.md`](RUST_PROTOCOL.md)

### M2 — Mock / stub workers for Linux integration tests

- [x] `voicey-infer-stub` (+ capture/fetch stubs in `voicey-worker-stubs`)
- [x] Supervisor + stub integration tests (`supervisor_integration.rs`)
- [x] Error paths: worker exit, timeout, malformed JSON, cancel download

### M3 — Expand unit coverage in existing crates

- [x] `voicey-supervisor` in-process `process.rs` tests
- [x] `voicey-fetch` HTTP tests (local test server in `manifest.rs`)
- [x] `voicey-capture` IPC + fixture tests (no microphone)

### M4 — CI matrix clarity

- [x] Tier 1 vs Tier 2 documented in [`RUST_RUNTIME.md`](RUST_RUNTIME.md) and workflow comments
- [x] Fast `rust-core` job separate from full workspace (`linux-rust-tests.yml`)
- [x] Rust toolchain pinned (`rust-toolchain.toml`, 1.86.0)

### M5 — Reduce macOS-only gates

- [x] Linux CI vs macOS ownership table in [`RUST_RUNTIME.md`](RUST_RUNTIME.md)
- [x] Move steering/glossary golden fixtures to shared JSON with Rust + Swift VoiceyCore tests (#134, #135, #136)
- [x] Move post-process golden fixtures to shared JSON with Rust + Swift VoiceyCore tests (#137)
- [ ] Remaining Swift runtime helpers → Rust / `VoiceyCore` (see [#70](https://github.com/jonathanKingston/voicey/issues/70) Phase 2+ fallback deletion)

### M6 — Longer term (deferred)

- [ ] Non-MLX infer backend for Linux CI smoke — [`CROSS_PLATFORM_DEFERRED.md`](CROSS_PLATFORM_DEFERRED.md)
- [ ] Optional headless Linux CLI host using `voicey-protocol` only

## Success criteria

- [x] Swift↔Rust JSON breakage fails Linux CI without Mac
- [x] Supervisor + fetch + capture regressions caught by stub integration tests
- [x] Single checklist for local vs CI guarantees (this file + linked docs)

## Related PRs

#75, #76, #86, #87, #88, #92, #93, #101, #104 (Tier 1 fetch), #123 (M2 worker I/O timeout), #119 (#73 release strip), #134–#137 (M5 golden parity), #138 (in progress — Rust capture PCM streaming for incremental transcription)

## Active implementation priority (May 2026)

Model/session lifecycle (#108, #139, #140–#142, #144 Linux validation) is complete on `main`. Incremental cancel (#147) is implemented on `main` (`f56ea29`, PR #148); exploration reconciled in PR #111 — remaining work is macOS QA only (see [#147](https://github.com/jonathanKingston/voicey/issues/147)).

**Open code PRs (do not duplicate):**

| PR | Scope | Gate |
|----|-------|------|
| [#138](https://github.com/jonathanKingston/voicey/pull/138) | `read_captured_samples` → incremental coordinator | [#145](https://github.com/jonathanKingston/voicey/issues/145) macOS QA |
| [#150](https://github.com/jonathanKingston/voicey/pull/150) | Screen-context capture gate before steering (#109) | macOS QA (can combine with #145) |

Consolidated macOS checklist: [`MACOS_MANUAL_QA.md`](MACOS_MANUAL_QA.md).

**What the #145 / #153 / #154 / #156 docs merges changed:** agents and contributors now have a single macOS QA doc ([`MACOS_MANUAL_QA.md`](MACOS_MANUAL_QA.md)); exploration docs link there instead of duplicating bullets (#154). #156 adds a paste-ready [#145](https://github.com/jonathanKingston/voicey/issues/145) sign-off template and clarifies in [`RUST_RUNTIME.md`](RUST_RUNTIME.md) that Rust-path incremental streaming lands with #138. That **unblocks manual QA sign-off** on #138/#150; it does **not** replace those PRs or allow Cloud Agent to validate mic/TCC/overlay behavior.

**What #159 changed (on `main`):** Rust `voicey-capture` utterances show a real transcribing-overlay progress waveform (`AudioWaveformEnvelope` from shared PCM) and finish routing is centralized in `UtteranceTranscriptionFinish` with Linux tests. That **partially unblocks** [#145](https://github.com/jonathanKingston/voicey/issues/145) sign-off for overlay UX on the default capture path; it does **not** land `read_captured_samples` incremental streaming ([#138](https://github.com/jonathanKingston/voicey/pull/138)) or screen-context gating ([#150](https://github.com/jonathanKingston/voicey/pull/150)).

**Automation assessment (Jun 2026, post-#159):** highest priority remains **#145 macOS QA** (human-only). Do not open duplicate PRs for #138/#150. Draft [#158](https://github.com/jonathanKingston/voicey/pull/158) holds post-#109 / #152 prep docs — do not duplicate that exploration file. [#138](https://github.com/jonathanKingston/voicey/pull/138) was rebased onto `main` after #159 (mergeable; still needs #145 before merge).

**Next implementation tranche (after #138/#150 merge + #145 sign-off):** [#152](https://github.com/jonathanKingston/voicey/issues/152) (Phase 2+ fallback deletion; parent [#70](https://github.com/jonathanKingston/voicey/issues/70)); capture layer first (`AudioCaptureManager` AVFoundation path) after #138 merge. Prep exploration: draft #158 / [`swift-hot-path-fallback-deletion.md`](explorations/swift-hot-path-fallback-deletion.md) when merged.
