//! Minimal fetch worker stub — enough for supervisor `fetch_ping` / download placeholder paths.

use serde::{Deserialize, Serialize};
use voicey_worker_stubs::run_jsonl_loop;

#[derive(Debug, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum FetchRequest {
    Ping { id: String },
    Shutdown { id: String },
}

#[derive(Debug, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum FetchResponse {
    Pong { id: String },
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
        FetchRequest::Shutdown { id } => FetchResponse::Ok { id },
    };

    serde_json::to_string(&response).expect("serialize fetch response")
}
