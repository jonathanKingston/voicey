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

#75, #76, #86, #87, #88, #92, #93, #101, #104 (Tier 1 fetch), #123 (M2 worker I/O timeout), #119 (#73 release strip), #134–#137 (M5 golden parity)
