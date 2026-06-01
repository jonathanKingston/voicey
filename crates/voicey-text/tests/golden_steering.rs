//! Shared golden JSON under `Benchmarks/Golden/steering/` — parity guard for Swift `TranscriptionSteeringContext`.

use std::fs;
use std::path::PathBuf;

use voicey_text::screen_term_selector;
use voicey_text::snapshot::ScreenContextSnapshot;
use voicey_text::steering::{build_steering_context, BuildSteeringContextInput};

#[derive(Debug, serde::Deserialize)]
struct WireSnapshot {
    query_text: String,
    corpus_chunks: Vec<String>,
}

#[derive(Debug, serde::Deserialize)]
struct GoldenFixture {
    description: String,
    manual_glossary_enabled: bool,
    #[serde(default)]
    manual_glossary: String,
    screen_context_enabled: bool,
    snapshot: Option<WireSnapshot>,
    #[serde(default)]
    max_terms: Option<usize>,
    expected_terms: Vec<String>,
    expected_decoder_context: Option<String>,
}

fn fixtures_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../Benchmarks/Golden/steering")
}

#[test]
fn golden_steering_fixtures_match_expected() {
    let dir = fixtures_dir();
    assert!(
        dir.is_dir(),
        "missing golden fixtures at {} (commit Benchmarks/Golden/steering/)",
        dir.display()
    );

    let mut paths: Vec<_> = fs::read_dir(&dir)
        .expect("read fixtures dir")
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .filter(|path| path.extension().is_some_and(|ext| ext == "json"))
        .collect();
    paths.sort();

    assert!(!paths.is_empty(), "no JSON fixtures in {}", dir.display());

    for path in paths {
        let name = path.file_name().unwrap().to_string_lossy();
        let raw = fs::read_to_string(&path).expect("read fixture");
        let fixture: GoldenFixture = serde_json::from_str(&raw)
            .unwrap_or_else(|error| panic!("{name}: invalid JSON: {error}"));

        let snapshot = fixture.snapshot.as_ref().map(|wire| ScreenContextSnapshot {
            query_text: wire.query_text.clone(),
            corpus_chunks: wire.corpus_chunks.clone(),
        });
        let max_terms = fixture
            .max_terms
            .unwrap_or(screen_term_selector::DEFAULT_MAX_TERMS);

        let actual = build_steering_context(&BuildSteeringContextInput {
            manual_glossary_enabled: fixture.manual_glossary_enabled,
            manual_glossary: &fixture.manual_glossary,
            screen_context_enabled: fixture.screen_context_enabled,
            snapshot: snapshot.as_ref(),
            max_terms,
        });

        assert_eq!(
            actual.terms, fixture.expected_terms,
            "{} ({}): terms mismatch",
            name, fixture.description
        );
        assert_eq!(
            actual.decoder_context, fixture.expected_decoder_context,
            "{} ({}): decoder_context mismatch",
            name, fixture.description
        );
    }
}
