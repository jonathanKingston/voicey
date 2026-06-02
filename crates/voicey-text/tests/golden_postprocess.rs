//! Shared golden JSON under `Benchmarks/Golden/postprocess/` — parity guard for Swift `PostProcessor`.

use std::fs;
use std::path::PathBuf;

use voicey_text::postprocess::{PostProcessInput, TranscriptionSegment};
use voicey_text::voice_command::VoiceCommand;

#[derive(Debug, serde::Deserialize)]
struct GoldenFixture {
    description: String,
    text: String,
    #[serde(default)]
    segments: Vec<WireSegment>,
    #[serde(default)]
    voice_commands_enabled: bool,
    #[serde(default)]
    voice_commands: Vec<VoiceCommand>,
    #[serde(default)]
    decoder_context: Option<String>,
    #[serde(default)]
    steering_terms: Vec<String>,
    expected: String,
}

#[derive(Debug, serde::Deserialize)]
struct WireSegment {
    text: String,
    start_time: f64,
    end_time: f64,
}

fn fixtures_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../Benchmarks/Golden/postprocess")
}

#[test]
fn golden_postprocess_fixtures_match_expected() {
    let dir = fixtures_dir();
    assert!(
        dir.is_dir(),
        "missing golden fixtures at {} (commit Benchmarks/Golden/postprocess/)",
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
        let input = PostProcessInput {
            text: fixture.text,
            segments: fixture
                .segments
                .into_iter()
                .map(|segment| TranscriptionSegment {
                    text: segment.text,
                    start_time: segment.start_time,
                    end_time: segment.end_time,
                })
                .collect(),
            voice_commands_enabled: fixture.voice_commands_enabled,
            voice_commands: fixture.voice_commands,
            decoder_context: fixture.decoder_context,
            steering_terms: fixture.steering_terms,
        };
        let actual = voicey_text::postprocess::postprocess(&input);
        assert_eq!(
            actual, fixture.expected,
            "{} ({}): postprocess mismatch",
            name, fixture.description
        );
    }
}
