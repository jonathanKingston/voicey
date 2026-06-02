//! JSONL worker loop for the `voicey-text` binary.

use crate::postprocess::{self, PostProcessInput, TranscriptionSegment};
use crate::snapshot::ScreenContextSnapshot;
use crate::steering::{self, BuildSteeringContextInput};
use crate::voice_command::VoiceCommand;
use serde::{Deserialize, Serialize};
use std::io::{BufRead, Write};

#[derive(Debug, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum TextRequest {
    Ping { id: String },
    Postprocess {
        id: String,
        text: String,
        voice_commands_enabled: bool,
        #[serde(default)]
        voice_commands: Vec<VoiceCommand>,
        #[serde(default)]
        segments: Vec<WireSegment>,
        #[serde(default)]
        decoder_context: Option<String>,
        #[serde(default)]
        steering_terms: Vec<String>,
    },
    BuildSteeringContext {
        id: String,
        manual_glossary_enabled: bool,
        #[serde(default)]
        manual_glossary: String,
        screen_context_enabled: bool,
        #[serde(default)]
        snapshot: Option<ScreenContextSnapshot>,
        #[serde(default)]
        max_terms: Option<usize>,
    },
    Shutdown { id: String },
}

#[derive(Debug, Deserialize)]
pub struct WireSegment {
    pub text: String,
    pub start_time: f64,
    pub end_time: f64,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum TextResponse {
    Pong { id: String },
    PostprocessResult {
        id: String,
        ok: bool,
        text: Option<String>,
        error: Option<String>,
    },
    SteeringContextResult {
        id: String,
        ok: bool,
        decoder_context: Option<String>,
        terms: Vec<String>,
        error: Option<String>,
    },
    Error { id: String, message: String },
}

pub fn run_jsonl_loop(mut input: impl BufRead, mut output: impl Write) -> std::io::Result<()> {
    let mut line = String::new();
    loop {
        line.clear();
        let read = input.read_line(&mut line)?;
        if read == 0 {
            break;
        }
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        let (response, should_shutdown) = handle_line(trimmed);
        let json = serde_json::to_string(&response).map_err(|error| {
            std::io::Error::new(std::io::ErrorKind::InvalidData, error)
        })?;
        writeln!(output, "{json}")?;
        output.flush()?;
        if should_shutdown {
            break;
        }
    }
    Ok(())
}

fn handle_line(line: &str) -> (TextResponse, bool) {
    let request: TextRequest = match serde_json::from_str(line) {
        Ok(value) => value,
        Err(error) => {
            return (
                TextResponse::Error {
                    id: String::new(),
                    message: format!("invalid request: {error}"),
                },
                false,
            );
        }
    };

    match request {
        TextRequest::Ping { id } => (TextResponse::Pong { id }, false),
        TextRequest::Postprocess {
            id,
            text,
            voice_commands_enabled,
            voice_commands,
            segments,
            decoder_context,
            steering_terms,
        } => {
            let input = PostProcessInput {
                text,
                segments: segments
                    .into_iter()
                    .map(|segment| TranscriptionSegment {
                        text: segment.text,
                        start_time: segment.start_time,
                        end_time: segment.end_time,
                    })
                    .collect(),
                voice_commands_enabled,
                voice_commands,
                decoder_context,
                steering_terms,
            };
            let processed = postprocess::postprocess(&input);
            (
                TextResponse::PostprocessResult {
                    id,
                    ok: true,
                    text: Some(processed),
                    error: None,
                },
                false,
            )
        }
        TextRequest::BuildSteeringContext {
            id,
            manual_glossary_enabled,
            manual_glossary,
            screen_context_enabled,
            snapshot,
            max_terms,
        } => {
            let max_terms = max_terms.unwrap_or(crate::screen_term_selector::DEFAULT_MAX_TERMS);
            let output = steering::build_steering_context(&BuildSteeringContextInput {
                manual_glossary_enabled,
                manual_glossary: &manual_glossary,
                screen_context_enabled,
                snapshot: snapshot.as_ref(),
                max_terms,
            });
            (
                TextResponse::SteeringContextResult {
                    id,
                    ok: true,
                    decoder_context: output.decoder_context,
                    terms: output.terms,
                    error: None,
                },
                false,
            )
        }
        TextRequest::Shutdown { id } => (
            TextResponse::PostprocessResult {
                id,
                ok: true,
                text: None,
                error: None,
            },
            true,
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    #[test]
    fn ping_returns_pong() {
        let input = Cursor::new("{\"type\":\"ping\",\"id\":\"1\"}\n");
        let mut output = Vec::new();
        run_jsonl_loop(input, &mut output).expect("jsonl loop");
        let response: TextResponse =
            serde_json::from_str(std::str::from_utf8(&output).unwrap().trim()).unwrap();
        assert!(matches!(response, TextResponse::Pong { id } if id == "1"));
    }

    #[test]
    fn postprocess_round_trip() {
        let request = r#"{"type":"postprocess","id":"2","text":"hello world","voice_commands_enabled":false}"#;
        let input = Cursor::new(format!("{request}\n"));
        let mut output = Vec::new();
        run_jsonl_loop(input, &mut output).expect("jsonl loop");
        let response: TextResponse =
            serde_json::from_str(std::str::from_utf8(&output).unwrap().trim()).unwrap();
        match response {
            TextResponse::PostprocessResult { ok, text, .. } => {
                assert!(ok);
                assert_eq!(text.as_deref(), Some("hello world"));
            }
            other => panic!("unexpected response: {other:?}"),
        }
    }

    #[test]
    fn build_steering_context_manual_glossary() {
        let request = r#"{"type":"build_steering_context","id":"3","manual_glossary_enabled":true,"manual_glossary":"Cursor","screen_context_enabled":false}"#;
        let input = Cursor::new(format!("{request}\n"));
        let mut output = Vec::new();
        run_jsonl_loop(input, &mut output).expect("jsonl loop");
        let response: TextResponse =
            serde_json::from_str(std::str::from_utf8(&output).unwrap().trim()).unwrap();
        match response {
            TextResponse::SteeringContextResult {
                ok,
                decoder_context,
                terms,
                ..
            } => {
                assert!(ok);
                assert_eq!(terms, vec!["Cursor".to_string()]);
                assert!(
                    decoder_context
                        .as_deref()
                        .unwrap_or("")
                        .contains("Cursor")
                );
            }
            other => panic!("unexpected response: {other:?}"),
        }
    }
}
