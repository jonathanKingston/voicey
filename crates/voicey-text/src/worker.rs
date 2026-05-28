//! JSONL worker loop for the `voicey-text` binary.

use crate::postprocess::{self, PostProcessInput, TranscriptionSegment};
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
}
