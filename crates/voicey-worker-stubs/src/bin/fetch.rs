//! Fetch worker stub for supervisor integration tests (list + staged download, no HTTP).

use std::fs;
use std::path::PathBuf;
use serde::{Deserialize, Serialize};
use voicey_protocol::FETCH_STAGING_DIRECTORY_NAME;
use voicey_worker_stubs::run_jsonl_loop;

#[derive(Debug, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum FetchRequest {
    Ping { id: String },
    ListModelFiles {
        id: String,
        model_id: String,
        #[allow(dead_code)]
        revision: Option<String>,
        #[allow(dead_code)]
        patterns: Vec<String>,
    },
    DownloadModelFile {
        id: String,
        model_id: String,
        relative_path: String,
        model_root: String,
        #[allow(dead_code)]
        revision: Option<String>,
        #[allow(dead_code)]
        expected_sha256: Option<String>,
    },
    Shutdown { id: String },
}

#[derive(Debug, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum FetchResponse {
    Pong { id: String },
    ListedModelFiles { id: String, files: Vec<String> },
    DownloadedModelFile { id: String, staged_path: String },
    Ok { id: String },
    Error { id: String, message: String },
}

fn main() {
    if std::env::var("VOICEY_FETCH_STUB_MODE")
        .ok()
        .as_deref()
        .map(str::trim)
        == Some("exit_on_start")
    {
        std::process::exit(1);
    }

    if let Err(error) = run_jsonl_loop(std::io::stdin().lock(), std::io::stdout(), handle_line) {
        eprintln!("voicey-fetch-stub fatal: {error}");
        std::process::exit(1);
    }
}

fn handle_line(line: &str) -> String {
    let request: FetchRequest = match serde_json::from_str(line) {
        Ok(value) => value,
        Err(error) => {
            return serde_json::to_string(&FetchResponse::Error {
                id: String::new(),
                message: format!("invalid request: {error}"),
            })
            .expect("serialize fetch error");
        }
    };

    let response = match request {
        FetchRequest::Ping { id } => FetchResponse::Pong { id },
        FetchRequest::ListModelFiles { id, model_id, .. } => {
            if !model_id.contains('/') {
                FetchResponse::Error {
                    id,
                    message: format!("expected HF org/repo id, got {model_id:?}"),
                }
            } else {
                FetchResponse::ListedModelFiles {
                    id,
                    files: vec!["config.json".into(), "model.safetensors".into()],
                }
            }
        }
        FetchRequest::DownloadModelFile {
            id,
            model_id,
            relative_path,
            model_root,
            ..
        } => {
            if !model_id.contains('/') {
                FetchResponse::Error {
                    id,
                    message: format!("expected HF org/repo id, got {model_id:?}"),
                }
            } else {
                match write_stub_file(&model_root, &relative_path) {
                    Ok(staged_path) => FetchResponse::DownloadedModelFile { id, staged_path },
                    Err(message) => FetchResponse::Error { id, message },
                }
            }
        }
        FetchRequest::Shutdown { id } => FetchResponse::Ok { id },
    };

    serde_json::to_string(&response).expect("serialize fetch response")
}

fn write_stub_file(model_root: &str, relative_path: &str) -> Result<String, String> {
    let staged = PathBuf::from(model_root)
        .join(FETCH_STAGING_DIRECTORY_NAME)
        .join(relative_path);
    if let Some(parent) = staged.parent() {
        fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    }
    fs::write(&staged, b"stub-weights").map_err(|error| error.to_string())?;
    staged
        .to_str()
        .map(str::to_string)
        .ok_or_else(|| "invalid staged path".to_string())
}
