//! Versioned IPC messages between Voicey host, supervisor, and workers.
//! Schema version 1 — bump `PROTOCOL_VERSION` when breaking changes ship.
//!
//! Shared PCM audio buffers use the `voicey-pcm` crate spec (temp-dir `.pcm` files).
//! Golden JSON fixtures live under `fixtures/`; see `docs/RUST_PROTOCOL.md`.

pub const PROTOCOL_VERSION: u32 = 1;

/// Staging subdirectory created by `voicey-fetch` under `model_root` (see `manifest.rs`).
pub const FETCH_STAGING_DIRECTORY_NAME: &str = ".voicey-fetch-staging";

/// Prefix for ephemeral download containers (mirrors Swift `VoiceyRustQwenDownloader`).
pub const FETCH_STAGING_CONTAINER_PREFIX: &str = ".voicey-fetch-download-";

/// Maps Voicey speech-model raw values to Hugging Face `org/repo` ids for fetch-worker IPC.
pub fn hugging_face_repo_id(voicey_model_id: &str) -> Result<&'static str, String> {
    match voicey_model_id {
        "qwen3-asr-0.6b-6bit" => Ok("aufklarer/Qwen3-ASR-0.6B-MLX-4bit"),
        "qwen3-asr-1.7b-bf16" => Ok("aufklarer/Qwen3-ASR-1.7B-MLX-8bit"),
        other => Err(format!("unsupported model_id for HF download: {other}")),
    }
}

/// Default file patterns for Qwen MLX weight downloads (mirrors Swift `VoiceyRustQwenDownloader`).
pub fn qwen_weight_list_patterns() -> Vec<String> {
    vec![
        "config.json".into(),
        "*.safetensors".into(),
        "model.safetensors.index.json".into(),
        "vocab.json".into(),
        "merges.txt".into(),
        "tokenizer_config.json".into(),
    ]
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RuntimeKind {
    InProcess,
    Multiprocess,
}

#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(tag = "type", rename_all = "snake_case", deny_unknown_fields)]
pub enum HostRequest {
    Ping { id: String },
    PrewarmAllWorkers { id: String, model_id: String },
    PrewarmInfer { id: String, model_id: String },
    PrewarmCapture { id: String },
    LoadModel { id: String, model_id: String },
    UnloadModel { id: String },
    Transcribe {
        id: String,
        model_id: String,
        sample_rate: u32,
        shm_name: String,
        sample_count: usize,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        decoder_context: Option<String>,
    },
    DownloadModel {
        id: String,
        model_id: String,
        destination_root: String,
    },
    CancelDownload { id: String, model_id: String },
    StartCapture { id: String },
    StopCapture { id: String },
    CaptureFixture {
        id: String,
        duration_seconds: f64,
    },
}

#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(tag = "type", rename_all = "snake_case", deny_unknown_fields)]
pub enum HostResponse {
    Pong { id: String },
    Ready { id: String },
    InferReady { id: String, model_id: String },
    CaptureReady { id: String },
    TranscribeResult {
        id: String,
        ok: bool,
        raw_text: Option<String>,
        language: Option<String>,
        processing_seconds: Option<f64>,
        audio_seconds: Option<f64>,
        error: Option<String>,
    },
    DownloadProgress {
        id: String,
        model_id: String,
        progress: f64,
    },
    DownloadComplete { id: String, model_id: String, path: String },
    DownloadFailed { id: String, model_id: String, error: String },
    CaptureStopped {
        id: String,
        shm_name: String,
        sample_count: usize,
        sample_rate: u32,
    },
    CaptureFixtureResult {
        id: String,
        ok: bool,
        shm_name: Option<String>,
        sample_count: Option<usize>,
        error: Option<String>,
    },
    Error { id: String, message: String },
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(tag = "type", rename_all = "snake_case", deny_unknown_fields)]
pub enum InferWorkerRequest {
    Ping { id: String },
    LoadModel { id: String, model_id: String },
    UnloadModel { id: String },
    Transcribe {
        id: String,
        model_id: String,
        sample_rate: u32,
        shm_name: String,
        sample_count: usize,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        decoder_context: Option<String>,
    },
    Shutdown { id: String },
}

#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(tag = "type", rename_all = "snake_case", deny_unknown_fields)]
pub enum InferWorkerResponse {
    Pong { id: String },
    Ready { id: String },
    InferReady { id: String, model_id: String },
    TranscribeResult {
        id: String,
        ok: bool,
        raw_text: Option<String>,
        language: Option<String>,
        processing_seconds: Option<f64>,
        audio_seconds: Option<f64>,
        error: Option<String>,
    },
    Error { id: String, message: String },
}

#[cfg(test)]
mod fixture_tests;
