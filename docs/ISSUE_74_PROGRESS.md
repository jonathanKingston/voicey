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
- [x] `voicey-capture` `read_captured_samples` for incremental transcription streaming (#138 on `main`, #166 race fix)
- [ ] Remaining Swift runtime helpers → Rust / `VoiceyCore` (see [#70](https://github.com/jonathanKingston/voicey/issues/70) Phase 2+ fallback deletion, [#152](https://github.com/jonathanKingston/voicey/issues/152))

### M6 — Longer term (deferred)

- [ ] Non-MLX infer backend for Linux CI smoke — [`CROSS_PLATFORM_DEFERRED.md`](CROSS_PLATFORM_DEFERRED.md)
- [ ] Optional headless Linux CLI host using `voicey-protocol` only

## Success criteria

- [x] Swift↔Rust JSON breakage fails Linux CI without Mac
- [x] Supervisor + fetch + capture regressions caught by stub integration tests
- [x] Single checklist for local vs CI guarantees (this file + linked docs)

## Related PRs

#75, #76, #86, #87, #88, #92, #93, #101, #104 (Tier 1 fetch), #123 (M2 worker I/O timeout), #119 (#73 release strip), #134–#137 (M5 golden parity), #138 (Rust capture PCM streaming), #166 (`read_samples_since` lock consistency)

## Active implementation priority (Jun 2026)

Model/session lifecycle (#108, #139, #140–#142, #144 Linux validation) is complete on `main`. Incremental cancel (#147) is implemented on `main` (`f56ea29`, PR #148). Rust capture incremental streaming (#138) and the `read_samples_since` race fix ([#166](https://github.com/jonathanKingston/voicey/pull/166)) are on `main`. macOS QA for the capture-streaming checklist ([#145](https://github.com/jonathanKingston/voicey/issues/145)) is **closed** (Jun 2026).

**Open code PRs (do not duplicate):**

| PR | Scope | Gate |
|----|-------|------|
| [#150](https://github.com/jonathanKingston/voicey/pull/150) | Screen-context capture gate before steering (#109) | macOS QA (optional combined pass; see [`MACOS_MANUAL_QA.md`](MACOS_MANUAL_QA.md)) |
| [#167](https://github.com/jonathanKingston/voicey/pull/167) | Paste-side steering/glossary sanitizer ([#162](https://github.com/jonathanKingston/voicey/issues/162)) | macOS spot-check |
| [#169](https://github.com/jonathanKingston/voicey/pull/169) | Hands-free utterance-2 finish via drained PCM ([#163](https://github.com/jonathanKingston/voicey/issues/163)) | macOS hands-free repro |

Consolidated macOS checklist: [`MACOS_MANUAL_QA.md`](MACOS_MANUAL_QA.md).

**Automation assessment (Jun 2026, post-#166):** [#166](https://github.com/jonathanKingston/voicey/pull/166) closes the blocking `read_samples_since` / `sample_count` race from #138 review (silent PCM loss between poll and copy). It does **not** replace review/merge of [#167](https://github.com/jonathanKingston/voicey/pull/167), [#169](https://github.com/jonathanKingston/voicey/pull/169), or [#150](https://github.com/jonathanKingston/voicey/pull/150). Do not open duplicate PRs for capture streaming, screen-context gate, paste sanitizer, or hands-free finish policy.

**Highest priority next work:** review and merge the open PRs above (human macOS QA where noted). Cloud Agent should not open a parallel implementation PR for those scopes.

**Next implementation tranche (after #150 merge):** [#152](https://github.com/jonathanKingston/voicey/issues/152) (Phase 2+ fallback deletion; parent [#70](https://github.com/jonathanKingston/voicey/issues/70)); capture layer first (`AudioCaptureManager` AVFoundation path). Prep exploration: [`swift-hot-path-fallback-deletion.md`](explorations/swift-hot-path-fallback-deletion.md). Capture deletion remains **merge-gated** on [#150](https://github.com/jonathanKingston/voicey/pull/150) landing so screen-context + incremental chunks are validated together.
