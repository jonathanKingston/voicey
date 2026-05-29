//! Shared JSONL loop helpers for test worker stubs (not shipped in production bundles).

use std::io::{BufRead, Write};

/// Reads newline-delimited JSON requests until EOF; invokes `handler` for each non-empty line.
pub fn run_jsonl_loop(
    mut input: impl BufRead,
    mut output: impl Write,
    mut handler: impl FnMut(&str) -> String,
) -> std::io::Result<()> {
    let mut line = String::new();
    loop {
        line.clear();
        if input.read_line(&mut line)? == 0 {
            break;
        }
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        let response = handler(trimmed);
        writeln!(output, "{response}")?;
        output.flush()?;
    }
    Ok(())
}

/// Infer stub behavior (set via `VOICEY_INFER_STUB_MODE`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InferStubMode {
    Normal,
    /// Exit immediately on startup (child dies before the supervisor talks to it).
    ExitOnStart,
    /// Exit when handling the first JSONL request (simulates worker crash mid-session).
    ExitOnFirstRequest,
    /// Emit invalid JSON on the first infer response line.
    MalformedResponse,
    /// `load_model` returns `Error`.
    FailLoad,
    /// `transcribe` always returns `ok: false` without MLX.
    FailTranscribe,
}

impl InferStubMode {
    pub fn from_env() -> Self {
        match std::env::var("VOICEY_INFER_STUB_MODE")
            .ok()
            .as_deref()
            .map(str::trim)
            .filter(|value| !value.is_empty())
        {
            Some("exit_on_start") => Self::ExitOnStart,
            Some("exit_on_first_request") => Self::ExitOnFirstRequest,
            Some("malformed_response") => Self::MalformedResponse,
            Some("fail_load") => Self::FailLoad,
            Some("fail_transcribe") => Self::FailTranscribe,
            _ => Self::Normal,
        }
    }
}
