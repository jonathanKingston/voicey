# Rust IPC protocol (`voicey-protocol`)

Contract tests keep the Swift host and Rust workers aligned without a Mac. JSON fixtures are **generated** from Rust types (not checked into git).

## Source of truth

| Artifact | Location |
|----------|----------|
| Schema types | [`crates/voicey-protocol/src/lib.rs`](../crates/voicey-protocol/src/lib.rs) |
| Generated fixtures | `crates/voicey-protocol/fixtures/` (gitignored; run `make protocol-fixtures`) |
| Swift mirror types | [`Sources/VoiceyCore/VoiceyProtocol.swift`](../Sources/VoiceyCore/VoiceyProtocol.swift) |
| Protocol version | `PROTOCOL_VERSION` in Rust, `VoiceyProtocol.version` in Swift (must match) |

## Generate fixtures

```bash
make protocol-fixtures
# or: cargo run -p voicey-protocol --bin gen-fixtures
```

CI runs this before Rust and Swift protocol tests. Run it locally before `swift test --filter VoiceyProtocolFixtureTests` if the fixtures directory is missing.

## CI

- **Rust:** generate fixtures → `cargo test -p voicey-protocol` — [`.github/workflows/linux-rust-tests.yml`](../.github/workflows/linux-rust-tests.yml)
- **Swift:** generate fixtures → `VoiceyProtocolFixtureTests` — [`.github/workflows/linux-core-tests.yml`](../.github/workflows/linux-core-tests.yml)

## Changing the protocol

1. Edit types in `crates/voicey-protocol/src/lib.rs`.
2. If the change is **breaking**, bump `PROTOCOL_VERSION` and `VoiceyProtocol.version`.
3. Run `make protocol-fixtures` and update `Sources/VoiceyCore/VoiceyProtocol.swift` for new variants/fields.
4. Run `make test-protocol` and `swift test --filter VoiceyProtocolFixtureTests`.
5. Ship Rust workers and the macOS app together so both sides speak the same version.

### Breaking vs non-breaking

| Change | Breaking? |
|--------|-----------|
| New optional field with `#[serde(default)]` | No |
| New request/response variant | Yes (bump version; coordinate deploy) |
| Rename `type` tag or field | Yes |
| Remove variant or field | Yes |

Rust enums use `deny_unknown_fields` so extra JSON keys fail deserialization during tests (and at runtime).

The Swift **infer-worker** subprocess must emit JSON that matches `InferWorkerResponse` (e.g. `infer_ready` has only `id` and `model_id` — not `ok`; use `transcribe_result` for success/failure flags).

## Fixture layout (generated)

```
fixtures/
  host_request/          # Host → supervisor
  host_response/         # Supervisor → host
  infer_worker_request/  # Supervisor → infer worker
  infer_worker_response/
  runtime_kind/
  reject/                # Negative cases (Rust-only strict checks)
```

## Related docs

- [RUST_RUNTIME.md](RUST_RUNTIME.md) — macOS worker binaries and env overrides
- GitHub [#74](https://github.com/jonathanKingston/voicey/issues/74) — Rust CI testability roadmap (M1–M6)
