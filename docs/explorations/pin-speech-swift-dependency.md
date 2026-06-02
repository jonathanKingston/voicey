# Pin speech-swift Dependency

## Status

Revision pin landed in `Package.swift` (post-#117 exploration). `Package.resolved` remains
gitignored (`.gitignore`); the manifest `revision:` is the committed source of truth for CI and
releases.

### Maintainer bump process

1. Choose a reviewed upstream tag or commit (`speech-swift` releases: `v0.0.x` on GitHub).
2. Update the `revision:` (or switch to `from:` when semver range is appropriate) in `Package.swift`.
3. On macOS: `swift package resolve`, `make build`, and Qwen smoke / relevant tests.
4. Note the old and new revision in the PR; do not track `branch: "main"` again.

## Summary

`speech-swift` is currently referenced by the Swift package manifest through its `main` branch.
That makes Voicey builds depend on whatever upstream commits are present when dependencies are
resolved, which is risky for reproducible releases and CI stability.

## Evidence

- `Package.swift` pins `.package(..., revision: "72a20dbb142d000b73d395b7bc62599fef8387e2")`
  (the revision previously resolved from `main` at exploration time).
- Voicey imports `Qwen3ASR` and `AudioCommon` products from that dependency.
- The README lists `speech-swift` as the native Swift MLX Qwen3 ASR runtime dependency.

Relevant files:

- `Package.swift`
- `Package.resolved`
- `README.md`
- `.github/workflows/build.yml`

## Risks

- CI can break without any Voicey source changes.
- Release rebuilds may resolve different dependency code than the reviewed build.
- Debugging regressions is harder when dependency updates are implicit.
- Supply-chain review cannot point to a stable revision.

## Proposed direction

Pin `speech-swift` to a stable version tag if one is available, or to a reviewed commit revision
if tags are not yet published. Document how maintainers intentionally update the pin.

Possible implementation shape:

1. Check upstream for the latest appropriate release tag or commit.
2. Replace `branch: "main"` with `from:` or `.revision(...)`.
3. Resolve dependencies and commit the updated `Package.resolved`.
4. Document the update process and compatibility checks.
5. Consider a scheduled dependency-update workflow once the pin is stable.

## Acceptance criteria

- `speech-swift` is not pinned to a moving branch.
- `Package.resolved` records the reviewed dependency state.
- CI uses the pinned dependency consistently.
- Release notes or docs explain how to update and validate the dependency.
- The selected tag/revision is justified in the PR description.

## Validation plan

- Run `swift package resolve` after changing the manifest.
- On macOS, run `make build` and the relevant runtime tests.
- Verify `Package.resolved` changes only as expected.
