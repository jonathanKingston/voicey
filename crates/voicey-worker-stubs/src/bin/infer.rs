//! Deterministic infer worker for supervisor integration tests (no MLX).

use voicey_protocol::{InferWorkerRequest, InferWorkerResponse};
use voicey_worker_stubs::{run_jsonl_loop, InferStubMode};

fn main() {
    let mode = InferStubMode::from_env();
    if mode == InferStubMode::ExitOnStart {
        std::process::exit(1);
    }

    let mut loaded_model: Option<String> = None;
    let mut malformed_pending = mode == InferStubMode::MalformedResponse;

    if let Err(error) = run_jsonl_loop(std::io::stdin().lock(), std::io::stdout(), |line| {
        if mode == InferStubMode::ExitOnFirstRequest {
            std::process::exit(1);
        }
        if malformed_pending {
            malformed_pending = false;
            return "not valid json\n".to_string();
        }
        handle_line(line, mode, &mut loaded_model)
    }) {
        eprintln!("voicey-infer-stub fatal: {error}");
        std::process::exit(1);
    }
}

fn handle_line(line: &str, mode: InferStubMode, loaded_model: &mut Option<String>) -> String {
    let request: InferWorkerRequest = match serde_json::from_str(line) {
        Ok(value) => value,
        Err(error) => {
            return serde_json::to_string(&InferWorkerResponse::Error {
                id: String::new(),
                message: format!("invalid request: {error}"),
            })
            .expect("serialize error response");
        }
    };

    let response = match request {
        InferWorkerRequest::Ping { id } => InferWorkerResponse::Pong { id },
        InferWorkerRequest::LoadModel { id, model_id } => {
            if mode == InferStubMode::FailLoad {
                InferWorkerResponse::Error {
                    id,
                    message: "stub: load_model forced failure".into(),
                }
            } else {
                *loaded_model = Some(model_id.clone());
                InferWorkerResponse::InferReady { id, model_id }
            }
        }
        InferWorkerRequest::UnloadModel { id } => {
            loaded_model.take();
            InferWorkerResponse::Ready { id }
        }
        InferWorkerRequest::Transcribe {
            id,
            model_id,
            sample_rate,
            shm_name,
            sample_count,
            sample_offset,
            decoder_context,
        } => {
            if mode == InferStubMode::FailTranscribe {
                InferWorkerResponse::TranscribeResult {
                    id,
                    ok: false,
                    raw_text: None,
                    language: None,
                    processing_seconds: None,
                    audio_seconds: None,
                    error: Some("stub: transcribe forced failure".into()),
                }
            } else if loaded_model.as_deref() != Some(model_id.as_str()) {
                InferWorkerResponse::TranscribeResult {
                    id,
                    ok: false,
                    raw_text: None,
                    language: None,
                    processing_seconds: None,
                    audio_seconds: None,
                    error: Some("stub: model not loaded".into()),
                }
            } else {
                let _ = voicey_pcm::read_f32_samples_slice(&shm_name, sample_offset, sample_count);
                let context_suffix = decoder_context
                    .as_deref()
                    .filter(|value| !value.is_empty())
                    .map(|value| format!(" ctx={value}"))
                    .unwrap_or_default();
                let audio_seconds = sample_count as f64 / f64::from(sample_rate.max(1));
                InferWorkerResponse::TranscribeResult {
                    id,
                    ok: true,
                    raw_text: Some(format!(
                        "stub-transcribe:{model_id}:{sample_count}{context_suffix}"
                    )),
                    language: Some("en".into()),
                    processing_seconds: Some(0.01),
                    audio_seconds: Some(audio_seconds),
                    error: None,
                }
            }
        }
        InferWorkerRequest::Shutdown { id } => InferWorkerResponse::Pong { id },
    };

    serde_json::to_string(&response).expect("serialize infer response")
}
