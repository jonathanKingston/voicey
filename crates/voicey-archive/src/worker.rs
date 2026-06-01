use crate::record::{
    AppendUtteranceMetadata, ArchiveAudioSource, UtteranceArchiveRecord,
    UtteranceArchiveScreenSnapshot,
};
use crate::store::SessionArchiveStore;
use serde::{Deserialize, Serialize};
use std::io::{BufRead, Write};
use std::path::PathBuf;

#[derive(Debug, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ArchiveRequest {
    Ping { id: String },
    AppendUtterance {
        id: String,
        archive_root: PathBuf,
        #[serde(default = "default_max_entries")]
        max_entries: usize,
        audio: ArchiveAudioSource,
        metadata: AppendUtteranceMetadata,
        #[serde(default)]
        snapshot: Option<UtteranceArchiveScreenSnapshot>,
    },
    DeleteAll {
        id: String,
        archive_root: PathBuf,
    },
    Shutdown { id: String },
}

fn default_max_entries() -> usize {
    500
}

#[derive(Debug, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ArchiveResponse {
    Pong { id: String },
    ArchiveResult {
        id: String,
        ok: bool,
        record: Option<UtteranceArchiveRecord>,
        error: Option<String>,
    },
    DeleteAllResult {
        id: String,
        ok: bool,
        error: Option<String>,
    },
    Error { id: String, message: String },
}

pub fn run_jsonl_loop(mut input: impl BufRead, mut output: impl Write) -> std::io::Result<()> {
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
        let (response, shutdown) = handle_line(trimmed);
        let json = serde_json::to_string(&response).map_err(|error| {
            std::io::Error::new(std::io::ErrorKind::InvalidData, error)
        })?;
        writeln!(output, "{json}")?;
        output.flush()?;
        if shutdown {
            break;
        }
    }
    Ok(())
}

fn handle_line(line: &str) -> (ArchiveResponse, bool) {
    let request: ArchiveRequest = match serde_json::from_str(line) {
        Ok(value) => value,
        Err(error) => {
            return (
                ArchiveResponse::Error {
                    id: String::new(),
                    message: format!("invalid request: {error}"),
                },
                false,
            );
        }
    };

    match request {
        ArchiveRequest::Ping { id } => (ArchiveResponse::Pong { id }, false),
        ArchiveRequest::AppendUtterance {
            id,
            archive_root,
            max_entries,
            audio,
            metadata,
            snapshot,
        } => {
            let store = SessionArchiveStore::new(archive_root);
            match store.append_utterance(&audio, &metadata, snapshot.as_ref(), max_entries) {
                Ok(record) => (
                    ArchiveResponse::ArchiveResult {
                        id,
                        ok: true,
                        record: Some(record),
                        error: None,
                    },
                    false,
                ),
                Err(message) => (
                    ArchiveResponse::ArchiveResult {
                        id,
                        ok: false,
                        record: None,
                        error: Some(message),
                    },
                    false,
                ),
            }
        }
        ArchiveRequest::DeleteAll { id, archive_root } => {
            let store = SessionArchiveStore::new(archive_root);
            match store.delete_all() {
                Ok(()) => (
                    ArchiveResponse::DeleteAllResult {
                        id,
                        ok: true,
                        error: None,
                    },
                    false,
                ),
                Err(message) => (
                    ArchiveResponse::DeleteAllResult {
                        id,
                        ok: false,
                        error: Some(message),
                    },
                    false,
                ),
            }
        }
        ArchiveRequest::Shutdown { id } => (ArchiveResponse::Pong { id }, true),
    }
}
