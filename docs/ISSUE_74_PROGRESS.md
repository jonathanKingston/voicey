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

#75, #76, #86, #87, #88, #92, #93, #101, #104 (Tier 1 fetch), #118 (architecture map), #123 (M2 worker I/O timeout), #119 (#73 release strip), #134–#137 (M5 golden parity), #138 (Rust capture PCM streaming), #166 (#138 follow-up), #167 (#162 steering-echo sanitizer + #152 text layer)

## Active implementation priority (Jun 2026)

Model/session lifecycle (#108, #139, #140–#142, #144 Linux validation) is complete on `main`. Incremental cancel (#147) is implemented on `main` (`f56ea29`, PR #148). #138 incremental Rust capture streaming and #166 `read_samples_since` fix are on `main`. #145 macOS QA is **closed** (Jun 2026). #162 paste-side steering sanitizer and #152 text/post-process fallback removal landed in #167 (`75c8142`).

**Open code PRs (do not duplicate):**

| PR | Scope | Gate |
|----|-------|------|
| [#150](https://github.com/jonathanKingston/voicey/pull/150) | Screen-context capture gate before steering (#109) | macOS spot-check (can combine with #145 sign-off scenarios) |
| [#169](https://github.com/jonathanKingston/voicey/pull/169) | Hands-free finish from drained PCM when incremental buffer is partial (#163) | macOS hands-free repro |
| [#181](https://github.com/jonathanKingston/voicey/pull/181) | Vocabulary decoder prefix, steering-echo hardening, opt-in dictation history (`voicey-archive`) | macOS: history panel + steering checklist |
| [#175](https://github.com/jonathanKingston/voicey/pull/175) | Shared PCM owner-only permissions + stale cleanup (#114) | Linux/Rust tests + macOS transcription spot-check |
| [#191](https://github.com/jonathanKingston/voicey/pull/191) | Steering context caps Phase A (8 / 32 / 256) — steering-only split from #181 | macOS dictation + busy IDE screen context |
| [#192](https://github.com/jonathanKingston/voicey/pull/192) | Local steering benchmark harness (dev-only; no user audio in git) | Developer workflow; not a product merge gate |

Consolidated macOS checklist: [`MACOS_MANUAL_QA.md`](MACOS_MANUAL_QA.md).

| Issue | Scope | Notes |
|-------|-------|-------|
| [#182](https://github.com/jonathanKingston/voicey/issues/182) | Dictation archive overlay save, export CLI, benchmark glue | After #181 lands or splits |

**Automation assessment (Jun 2026, post-#167):** #167 closes [#162](https://github.com/jonathanKingston/voicey/issues/162) (steering-echo sanitization in `voicey-text` `postprocess`; Swift post-process/steering fallbacks removed). It also completes the **text layer** of [#152](https://github.com/jonathanKingston/voicey/issues/152). **Does not** unblock capture fallback deletion until [#150](https://github.com/jonathanKingston/voicey/pull/150) merges. **Highest priority next work:** review/merge #150 and #169 (macOS spot-check where noted). Do not duplicate #150 or #169.

**Automation assessment (Jun 2026, post-#172):** [#172](https://github.com/jonathanKingston/voicey/pull/172) aligns [#147](https://github.com/jonathanKingston/voicey/issues/147) cancel rows in [`MACOS_MANUAL_QA.md`](MACOS_MANUAL_QA.md) with the closed issue; it does **not** unblock new implementation PRs. Priority queue unchanged: merge [#150](https://github.com/jonathanKingston/voicey/pull/150) and [#169](https://github.com/jonathanKingston/voicey/pull/169) on macOS; then [#152](https://github.com/jonathanKingston/voicey/issues/152) capture fallback deletion.

**Suggested GitHub issue comments** (Cloud Agent token lacks `issues: write` — paste manually if helpful):

- **#152:** Text/post-process layer done in #167. Capture (`AVAudioEngine`) deletion remains blocked until #150 merges + macOS QA. Do not open duplicate PRs for #150 / #169.
- **#163:** Fix is in open PR #169 (`UtteranceTranscriptionFinishPolicy`); merge gate is macOS hands-free multi-utterance repro per [`MACOS_MANUAL_QA.md`](MACOS_MANUAL_QA.md).
- **#185:** Closed by #186 — `Package.swift` uses `revision:`; bump process in [`pin-speech-swift-dependency.md`](explorations/pin-speech-swift-dependency.md).

**Next implementation tranche (after #150 merge):** [#152](https://github.com/jonathanKingston/voicey/issues/152) capture layer (`AudioCaptureManager` AVFoundation path deletion), then fetch Hub fallback. Prep exploration: [`swift-hot-path-fallback-deletion.md`](explorations/swift-hot-path-fallback-deletion.md).

**Automation assessment (Jun 2026, post-#117):** [#117](https://github.com/jonathanKingston/voicey/pull/117) exploration on `main` documents `speech-swift` supply-chain risk; it does **not** unblock [#150](https://github.com/jonathanKingston/voicey/pull/150) / [#169](https://github.com/jonathanKingston/voicey/pull/169) or [#152](https://github.com/jonathanKingston/voicey/issues/152) capture work. Pin follow-up landed in [#186](https://github.com/jonathanKingston/voicey/pull/186) (closes [#185](https://github.com/jonathanKingston/voicey/issues/185)).

**Automation assessment (Jun 2026, post-#186):** [#186](https://github.com/jonathanKingston/voicey/pull/186) pins `speech-swift` to reviewed revision `72a20db` in `Package.swift` (same commit previously resolved from `main`; see [`pin-speech-swift-dependency.md`](explorations/pin-speech-swift-dependency.md)). **Does not** unblock [#150](https://github.com/jonathanKingston/voicey/pull/150) / [#169](https://github.com/jonathanKingston/voicey/pull/169) or [#152](https://github.com/jonathanKingston/voicey/issues/152) capture fallback deletion. **Does** close the #117 supply-chain follow-up ([#185](https://github.com/jonathanKingston/voicey/issues/185)). **Highest priority unchanged:** macOS review/merge **#150** and **#169**; do not duplicate those PRs or **#181** / **#175**.

**Automation assessment (Jun 2026, post-#116):** [#116](https://github.com/jonathanKingston/voicey/pull/116) exploration reconciled the macOS CI gap (hand-maintained `--filter` allowlist omitted 4 of 9 `VoiceyTests` classes; full target passes headlessly). **Does** unblock CI hardening: run `swift test --filter VoiceyTests` instead of the allowlist (see [`macos-voiceytests-ci.md`](explorations/macos-voiceytests-ci.md)). **Does not** unblock [#150](https://github.com/jonathanKingston/voicey/pull/150) / [#169](https://github.com/jonathanKingston/voicey/pull/169) or [#152](https://github.com/jonathanKingston/voicey/issues/152) capture fallback deletion. **Highest priority unchanged:** macOS review/merge **#150** and **#169**; do not duplicate those PRs or **#181** / **#175**.

**Automation assessment (Jun 2026, post-#189):** [#189](https://github.com/jonathanKingston/voicey/pull/189) landed the #116 follow-up on `main` (`swift test --filter VoiceyTests` in `build.yml`). **Closes** the macOS CI allowlist gap. **Does not** unblock [#150](https://github.com/jonathanKingston/voicey/pull/150) / [#169](https://github.com/jonathanKingston/voicey/pull/169) or [#152](https://github.com/jonathanKingston/voicey/issues/152) capture fallback deletion. **Highest priority unchanged:** macOS review/merge **#150** and **#169**; do not duplicate those PRs or **#181** / **#175** / **#188** ([#113](https://github.com/jonathanKingston/voicey/issues/113) logging).

**Automation assessment (Jun 2026, post-#190):** [#190](https://github.com/jonathanKingston/voicey/pull/190) on `main` adds `voiceytests.log` artifact upload on macOS CI failure and marks [`macos-voiceytests-ci.md`](explorations/macos-voiceytests-ci.md) implemented. **Closes** the #116 / #189 CI hygiene tranche. **Does not** unblock [#150](https://github.com/jonathanKingston/voicey/pull/150) / [#169](https://github.com/jonathanKingston/voicey/pull/169) or [#152](https://github.com/jonathanKingston/voicey/issues/152) capture fallback deletion. **Highest priority unchanged:** macOS review/merge **#150** and **#169** per [`MACOS_MANUAL_QA.md`](MACOS_MANUAL_QA.md); do not duplicate **#150**, **#169**, **#181**, **#175**, **#188**, **#191**, or **#192**. **Cloud Agent cycle:** rebased **#150** and **#169** onto `main` (includes #190); Linux: 8/8 `ScreenContextCaptureGateTests`, 4/4 `UtteranceTranscriptionFinishPolicyTests`.

**Automation assessment (Jun 2026, post-#193):** [#193](https://github.com/jonathanKingston/voicey/pull/193) records the post-#190 queue on `main` (no new implementation). **Does not** unblock product work. **Highest priority unchanged:** macOS review/merge **#150** and **#169**. **Cloud Agent cycle (this run):** rebased **#150** / **#169** onto `a59df7c` (`main`); Linux: 8/8 `ScreenContextCaptureGateTests`, 4/4 `UtteranceTranscriptionFinishPolicyTests`. Refreshed [`swift-hot-path-fallback-deletion.md`](explorations/swift-hot-path-fallback-deletion.md) — #138 is on `main`; [#152](https://github.com/jonathanKingston/voicey/issues/152) capture deletion remains blocked on **#150** only.

**Automation assessment (Jun 2026, post-#194):** [#194](https://github.com/jonathanKingston/voicey/pull/194) on `main` is docs-only (post-#193 queue + #152 gates). **Does not** unblock new implementation PRs. **Highest priority unchanged:** macOS review/merge **#150** and **#169** per [`MACOS_MANUAL_QA.md`](MACOS_MANUAL_QA.md); do not duplicate **#150**, **#169**, **#181**, **#175**, **#188**, **#191**, or **#192**. **Parallel (not blocking):** draft **#175** (#114 PCM hardening) rebased on `main`. **Cloud Agent cycle (this run):** rebased **#150** / **#169** / **#175** onto `e08ee6c`; Linux: 8/8 `ScreenContextCaptureGateTests`, 4/4 `UtteranceTranscriptionFinishPolicyTests`, 6/6 `voicey-pcm`. [#152](https://github.com/jonathanKingston/voicey/issues/152) capture deletion remains blocked on **#150** merge only.

**Automation assessment (Jun 2026, post-#195):** [#195](https://github.com/jonathanKingston/voicey/pull/195) on `main` is docs-only (post-#194 queue; rebased open PR branches). **Does not** unblock new implementation PRs. **Highest priority unchanged:** macOS review/merge **#150** and **#169** per [`MACOS_MANUAL_QA.md`](MACOS_MANUAL_QA.md); do not duplicate **#150**, **#169**, **#181**, **#175**, **#188**, **#191**, or **#192**. **Next implementation tranche (after #150 merge):** [#152](https://github.com/jonathanKingston/voicey/issues/152) capture fallback deletion only — blocked on **#150** merge + macOS QA. **Cloud Agent cycle (this run):** rebased **#150** / **#169** / **#175** onto `f0a905a` (`main`); Linux: 8/8 `ScreenContextCaptureGateTests`, 4/4 `UtteranceTranscriptionFinishPolicyTests`, 6/6 `voicey-pcm`.

**Automation assessment (Jun 2026, post-#196):** [#196](https://github.com/jonathanKingston/voicey/pull/196) on `main` is docs-only (post-#195 queue; rebased open PR branches). **Does not** unblock new implementation PRs. **Highest priority unchanged:** macOS review/merge **#150** and **#169** per [`MACOS_MANUAL_QA.md`](MACOS_MANUAL_QA.md); do not duplicate **#150**, **#169**, **#181**, **#175**, **#188**, **#191**, or **#192**. **Next implementation tranche (after #150 merge):** [#152](https://github.com/jonathanKingston/voicey/issues/152) capture fallback deletion only — blocked on **#150** merge + macOS QA. **Cloud Agent cycle (this run):** rebased **#150** / **#169** / **#175** onto `94b1645` (`main`); Linux: 8/8 `ScreenContextCaptureGateTests`, 4/4 `UtteranceTranscriptionFinishPolicyTests`, 6/6 `voicey-pcm`.

**Automation assessment (Jun 2026, post-#197):** [#197](https://github.com/jonathanKingston/voicey/pull/197) on `main` is docs-only (post-#196 queue; rebased open PR branches). **Does not** unblock new implementation PRs. **Highest priority unchanged:** macOS review/merge **#150** and **#169** per [`MACOS_MANUAL_QA.md`](MACOS_MANUAL_QA.md); do not duplicate **#150**, **#169**, **#181**, **#175**, **#188**, **#191**, or **#192**. **Next implementation tranche (after #150 merge):** [#152](https://github.com/jonathanKingston/voicey/issues/152) capture fallback deletion only — blocked on **#150** merge + macOS QA. **Cloud Agent cycle (this run):** rebased **#150** / **#169** / **#175** onto `8233c23` (`main`); Linux: 8/8 `ScreenContextCaptureGateTests`, 4/4 `UtteranceTranscriptionFinishPolicyTests`, 6/6 `voicey-pcm`.

**Automation assessment (Jun 2026, post-#198):** [#198](https://github.com/jonathanKingston/voicey/pull/198) on `main` is docs-only (post-#197 queue; rebased open PR branches). **Does not** unblock new implementation PRs. **Highest priority unchanged:** macOS review/merge **#150** and **#169** per [`MACOS_MANUAL_QA.md`](MACOS_MANUAL_QA.md); do not duplicate **#150**, **#169**, **#181**, **#175**, **#188**, **#191**, or **#192**. **Next implementation tranche (after #150 merge):** [#152](https://github.com/jonathanKingston/voicey/issues/152) capture fallback deletion only — blocked on **#150** merge + macOS QA.

**Automation assessment (Jun 2026, post-#118):** [#118](https://github.com/jonathanKingston/voicey/pull/118) on `main` refreshes [`ARCHITECTURE.md`](ARCHITECTURE.md) (Mermaid system map, directory ownership, runtime worker table, links to [`RUST_RUNTIME.md`](RUST_RUNTIME.md) / CI / issues). **Does not** unblock [#150](https://github.com/jonathanKingston/voicey/pull/150) / [#169](https://github.com/jonathanKingston/voicey/pull/169) or [#152](https://github.com/jonathanKingston/voicey/issues/152) capture fallback deletion — it improves onboarding and agent navigation only. **Highest priority unchanged:** macOS review/merge **#150** and **#169**; do not duplicate **#150**, **#169**, **#181**, **#175**, **#188**, **#191**, or **#192**. **Next implementation tranche (after #150 merge):** [#152](https://github.com/jonathanKingston/voicey/issues/152) capture layer per [`swift-hot-path-fallback-deletion.md`](explorations/swift-hot-path-fallback-deletion.md). **Cloud Agent cycle (this run):** rebased **#150** / **#169** / **#175** onto `85ff14c` (`main`); Linux: 8/8 `ScreenContextCaptureGateTests`, 4/4 `UtteranceTranscriptionFinishPolicyTests`, 6/6 `voicey-pcm`.

**Automation assessment (Jun 2026, post-#200):** [#200](https://github.com/jonathanKingston/voicey/pull/200) on `main` records the post-#118 queue (no new implementation). **Does not** unblock new implementation PRs. **Highest priority unchanged:** macOS review/merge **#150** and **#169** per [`MACOS_MANUAL_QA.md`](MACOS_MANUAL_QA.md); do not duplicate **#150**, **#169**, **#181**, **#175**, **#188**, **#191**, or **#192**. **Next implementation tranche (after #150 merge):** [#152](https://github.com/jonathanKingston/voicey/issues/152) capture fallback deletion only — blocked on **#150** merge + macOS QA. **Cloud Agent cycle (this run):** rebased **#150** / **#169** / **#175** onto `3515874` (`main`); Linux: 8/8 `ScreenContextCaptureGateTests`, 4/4 `UtteranceTranscriptionFinishPolicyTests`, 6/6 `voicey-pcm`.

**Automation assessment (Jun 2026, post-#201):** [#201](https://github.com/jonathanKingston/voicey/pull/201) on `main` records the post-#200 queue (no new implementation). **Does not** unblock new implementation PRs. **Highest priority unchanged:** macOS review/merge **#150** and **#169** per [`MACOS_MANUAL_QA.md`](MACOS_MANUAL_QA.md); do not duplicate **#150**, **#169**, **#181**, **#175**, **#188**, **#191**, or **#192**. **Next implementation tranche (after #150 merge):** [#152](https://github.com/jonathanKingston/voicey/issues/152) capture fallback deletion only — blocked on **#150** merge + macOS QA. **Cloud Agent cycle (this run):** rebased **#150** / **#169** / **#175** onto `956b01a` (`main`); Linux: 8/8 `ScreenContextCaptureGateTests`, 4/4 `UtteranceTranscriptionFinishPolicyTests`, 6/6 `voicey-pcm`.

**Automation assessment (Jun 2026, post-#202):** [#202](https://github.com/jonathanKingston/voicey/pull/202) on `main` records the post-#201 queue (no new implementation). **Does not** unblock new implementation PRs. **Highest priority unchanged:** macOS review/merge **#150** and **#169** per [`MACOS_MANUAL_QA.md`](MACOS_MANUAL_QA.md); do not duplicate **#150**, **#169**, **#181**, **#175**, **#188**, **#191**, or **#192**. **Next implementation tranche (after #150 merge):** [#152](https://github.com/jonathanKingston/voicey/issues/152) capture fallback deletion only — blocked on **#150** merge + macOS QA. **Cloud Agent cycle (this run):** rebased **#150** / **#169** / **#175** onto `c022a8b` (`main`); Linux: 8/8 `ScreenContextCaptureGateTests`, 4/4 `UtteranceTranscriptionFinishPolicyTests`, 6/6 `voicey-pcm`.

**Automation assessment (Jun 2026, post-#203):** [#203](https://github.com/jonathanKingston/voicey/pull/203) on `main` records the post-#202 queue (no new implementation). **Does not** unblock new implementation PRs. **Highest priority unchanged:** macOS review/merge **#150** and **#169** per [`MACOS_MANUAL_QA.md`](MACOS_MANUAL_QA.md); do not duplicate **#150**, **#169**, **#181**, **#175**, **#188**, **#191**, or **#192**. **Next implementation tranche (after #150 merge):** [#152](https://github.com/jonathanKingston/voicey/issues/152) capture fallback deletion only — blocked on **#150** merge + macOS QA. **Cloud Agent cycle (this run):** rebased **#150** / **#169** / **#175** onto `594ddf2` (`main`); Linux: 8/8 `ScreenContextCaptureGateTests`, 4/4 `UtteranceTranscriptionFinishPolicyTests`, 6/6 `voicey-pcm`.
