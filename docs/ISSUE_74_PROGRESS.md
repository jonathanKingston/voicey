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
- [x] `voicey-capture` `read_captured_samples` for incremental transcription streaming (Linux IPC tests)
- [ ] Remaining Swift runtime helpers → Rust / bundled workers (see [#70](https://github.com/jonathanKingston/voicey/issues/70) Phase 2+ fallback deletion — text layer done in #167; capture/fetch remain)

### M6 — Longer term (deferred)

- [ ] Non-MLX infer backend for Linux CI smoke — [`CROSS_PLATFORM_DEFERRED.md`](CROSS_PLATFORM_DEFERRED.md)
- [ ] Optional headless Linux CLI host using `voicey-protocol` only

## Success criteria

- [x] Swift↔Rust JSON breakage fails Linux CI without Mac
- [x] Supervisor + fetch + capture regressions caught by stub integration tests
- [x] Single checklist for local vs CI guarantees (this file + linked docs)

## Related PRs

#75, #76, #86, #87, #88, #92, #93, #101, #104 (Tier 1 fetch), #123 (M2 worker I/O timeout), #119 (#73 release strip), #134–#137 (M5 golden parity), #138 (Rust capture PCM streaming), #166 (#138 follow-up), #167 (#162 steering-echo sanitizer + #152 text layer)

## Active implementation priority (Jun 2026)

Model/session lifecycle (#108, #139, #140–#142, #144 Linux validation) is complete on `main`. Incremental cancel (#147) is implemented on `main` (`f56ea29`, PR #148). #138 incremental Rust capture streaming and #166 `read_samples_since` fix are on `main`. #145 macOS QA is **closed** (Jun 2026). #162 paste-side steering sanitizer and #152 text/post-process fallback removal landed in #167 (`75c8142`).

**Open code PRs (do not duplicate):**

| PR | Scope | Gate |
|----|-------|------|
| [#150](https://github.com/jonathanKingston/voicey/pull/150) | Screen-context capture gate before steering (#109) | macOS spot-check (can combine with #145 sign-off scenarios) |
| [#169](https://github.com/jonathanKingston/voicey/pull/169) | Hands-free finish from drained PCM when incremental buffer is partial (#163) | macOS hands-free repro |

Consolidated macOS checklist: [`MACOS_MANUAL_QA.md`](MACOS_MANUAL_QA.md).

**Automation assessment (Jun 2026, post-#167):** #167 closes [#162](https://github.com/jonathanKingston/voicey/issues/162) (steering-echo sanitization in `voicey-text` `postprocess`; Swift post-process/steering fallbacks removed). It also completes the **text layer** of [#152](https://github.com/jonathanKingston/voicey/issues/152). **Does not** unblock capture fallback deletion until [#150](https://github.com/jonathanKingston/voicey/pull/150) merges. **Highest priority next work:** review/merge #150 and #169 (macOS spot-check where noted). Do not duplicate #150 or #169.

**Automation assessment (Jun 2026, post-#172):** [#172](https://github.com/jonathanKingston/voicey/pull/172) aligns [#147](https://github.com/jonathanKingston/voicey/issues/147) cancel rows in [`MACOS_MANUAL_QA.md`](MACOS_MANUAL_QA.md) with the closed issue; it does **not** unblock new implementation PRs. Priority queue unchanged: merge [#150](https://github.com/jonathanKingston/voicey/pull/150) and [#169](https://github.com/jonathanKingston/voicey/pull/169) on macOS; then [#152](https://github.com/jonathanKingston/voicey/issues/152) capture fallback deletion.

**Suggested GitHub issue comments** (Cloud Agent token lacks `issues: write` — paste manually if helpful):

- **#152:** Text/post-process layer done in #167. Capture (`AVAudioEngine`) deletion remains blocked until #150 merges + macOS QA. Do not open duplicate PRs for #150 / #169.
- **#163:** Fix is in draft PR #169 (`UtteranceTranscriptionFinishPolicy`); merge gate is macOS hands-free multi-utterance repro per [`MACOS_MANUAL_QA.md`](MACOS_MANUAL_QA.md).

**Next implementation tranche (after #150 merge):** [#152](https://github.com/jonathanKingston/voicey/issues/152) capture layer (`AudioCaptureManager` AVFoundation path deletion), then fetch Hub fallback. Prep exploration: [`swift-hot-path-fallback-deletion.md`](explorations/swift-hot-path-fallback-deletion.md).

**Automation assessment (Jun 2026, post-#180):** [#180](https://github.com/jonathanKingston/voicey/pull/180) adds the session-archive design doc only — it does **not** unblock [#150](https://github.com/jonathanKingston/voicey/pull/150) / [#169](https://github.com/jonathanKingston/voicey/pull/169) / [#152](https://github.com/jonathanKingston/voicey/issues/152). It **does** unblock planning and review of dictation history work: implementation is in open [#181](https://github.com/jonathanKingston/voicey/pull/181) (rebased onto `main`); overlay save + export CLI tracked in [#182](https://github.com/jonathanKingston/voicey/issues/182). **Highest priority unchanged:** macOS review/merge **#150** and **#169**; do not duplicate those PRs or #181.

| PR / issue | Scope | Gate |
|------------|-------|------|
| [#181](https://github.com/jonathanKingston/voicey/pull/181) | Vocabulary decoder prefix, steering-echo hardening, opt-in dictation history (`voicey-archive`) | macOS: history panel + steering checklist |
| [#182](https://github.com/jonathanKingston/voicey/issues/182) | Overlay save, export CLI, benchmark glue (design phases 1 + 3–4) | After #181 lands or splits |
