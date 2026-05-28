# Rust IPC protocol (`voicey-protocol`)

Golden JSON fixtures and contract tests keep the Swift host and Rust workers aligned without a Mac.

## Source of truth

| Artifact | Location |
|----------|----------|
| Schema types | [`crates/voicey-protocol/src/lib.rs`](../crates/voicey-protocol/src/lib.rs) |
| Golden fixtures | [`crates/voicey-protocol/fixtures/`](../crates/voicey-protocol/fixtures/) |
| Swift mirror types | [`Sources/VoiceyCore/VoiceyProtocol.swift`](../Sources/VoiceyCore/VoiceyProtocol.swift) (tests read fixtures from the crate path above) |
| Protocol version | `PROTOCOL_VERSION` in Rust, `VoiceyProtocol.version` in Swift (must match) |

## CI

- **Rust:** `cargo test -p voicey-protocol` (fixture round-trip, reject unknown fields/types) — see [`.github/workflows/linux-rust-tests.yml`](../.github/workflows/linux-rust-tests.yml).
- **Swift:** `VoiceyProtocolFixtureTests` decodes the same fixture files — see [`.github/workflows/linux-core-tests.yml`](../.github/workflows/linux-core-tests.yml).

## Changing the protocol

1. Edit types in `crates/voicey-protocol/src/lib.rs`.
2. If the change is **breaking**, bump `PROTOCOL_VERSION` and `VoiceyProtocol.version`.
3. Regenerate fixtures:
   ```bash
   cargo run -p voicey-protocol --bin gen-fixtures
   ```
4. Update `Sources/VoiceyCore/VoiceyProtocol.swift` to match new variants/fields.
5. Run `cargo test -p voicey-protocol` and `swift test --filter VoiceyProtocolFixtureTests`.
6. Ship Rust workers and the macOS app together so both sides speak the same version.

### Breaking vs non-breaking

| Change | Breaking? |
|--------|-----------|
| New optional field with `#[serde(default)]` | No |
| New request/response variant | Yes (bump version; coordinate deploy) |
| Rename `type` tag or field | Yes |
| Remove variant or field | Yes |

Rust enums use `deny_unknown_fields` so extra JSON keys fail deserialization during tests (and at runtime).

## Fixture layout

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
