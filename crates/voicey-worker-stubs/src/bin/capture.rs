//! Deterministic capture worker stub (no microphone / cpal).

use serde::{Deserialize, Serialize};
use voicey_worker_stubs::run_jsonl_loop;

#[derive(Debug, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum CaptureRequest {
    Ping { id: String },
    Prewarm { id: String },
    RecordFixture { id: String, duration_seconds: f64 },
    Shutdown { id: String },
}

#[derive(Debug, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum CaptureResponse {
    Pong { id: String },
    CaptureReady { id: String },
    CaptureFixtureResult {
        id: String,
        ok: bool,
        shm_name: Option<String>,
        sample_count: Option<usize>,
        sample_rate: Option<u32>,
        #[serde(skip_serializing_if = "Option::is_none")]
        non_zero_sample_count: Option<usize>,
        error: Option<String>,
    },
    Error { id: String, message: String },
}

fn main() {
    if let Err(error) = run_jsonl_loop(std::io::stdin().lock(), std::io::stdout(), handle_line) {
        eprintln!("voicey-capture-stub fatal: {error}");
        std::process::exit(1);
    }
}

fn handle_line(line: &str) -> String {
    let request: CaptureRequest = match serde_json::from_str(line) {
        Ok(value) => value,
        Err(error) => {
            return serde_json::to_string(&CaptureResponse::Error {
                id: String::new(),
                message: format!("invalid request: {error}"),
            })
            .expect("serialize capture error");
        }
    };

    let response = match request {
        CaptureRequest::Ping { id } => CaptureResponse::Pong { id },
        CaptureRequest::Prewarm { id } => CaptureResponse::CaptureReady { id },
        CaptureRequest::RecordFixture { id, duration_seconds } => {
            if duration_seconds <= 0.0 || duration_seconds > 30.0 {
                CaptureResponse::CaptureFixtureResult {
                    id,
                    ok: false,
                    shm_name: None,
                    sample_count: None,
                    sample_rate: None,
                    non_zero_sample_count: None,
                    error: Some("duration out of range".into()),
                }
            } else {
                let sample_count = (duration_seconds * 16_000.0).round() as usize;
                let samples = vec![0.0_f32; sample_count.max(1)];
                match voicey_pcm::write_f32_samples(&samples) {
                    Ok(shm_name) => CaptureResponse::CaptureFixtureResult {
                        id,
                        ok: true,
                        shm_name: Some(shm_name),
                        sample_count: Some(samples.len()),
                        sample_rate: Some(16_000),
                        non_zero_sample_count: Some(0),
                        error: None,
                    },
                    Err(error) => CaptureResponse::CaptureFixtureResult {
                        id,
                        ok: false,
                        shm_name: None,
                        sample_count: None,
                        sample_rate: None,
                        non_zero_sample_count: None,
                        error: Some(error.to_string()),
                    },
                }
            }
        }
        CaptureRequest::Shutdown { id } => CaptureResponse::Pong { id },
    };

    serde_json::to_string(&response).expect("serialize capture response")
}
