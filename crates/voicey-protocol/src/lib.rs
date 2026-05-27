//! Versioned IPC messages between Voicey host, supervisor, and workers.
//! Schema version 1 — bump `PROTOCOL_VERSION` when breaking changes ship.

pub const PROTOCOL_VERSION: u32 = 1;

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RuntimeKind {
    InProcess,
    Multiprocess,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
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
        #[serde(default)]
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

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
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

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
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
        #[serde(default)]
        decoder_context: Option<String>,
    },
    Shutdown { id: String },
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
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
mod tests {
    use super::*;

    #[test]
    fn host_request_prewarm_roundtrip() {
        let req = HostRequest::PrewarmInfer {
            id: "1".into(),
            model_id: "qwen3-asr-0.6b-6bit".into(),
        };
        let json = serde_json::to_string(&req).unwrap();
        let back: HostRequest = serde_json::from_str(&json).unwrap();
        assert!(matches!(back, HostRequest::PrewarmInfer { .. }));
    }

    #[test]
    fn host_request_transcribe_roundtrip() {
        let req = HostRequest::Transcribe {
            id: "1".into(),
            model_id: "qwen3-asr-0.6b-6bit".into(),
            sample_rate: 16_000,
            shm_name: "voicey-pcm-test".into(),
            sample_count: 1024,
            decoder_context: Some("Glossary: Voicey".into()),
        };
        let json = serde_json::to_string(&req).unwrap();
        let back: HostRequest = serde_json::from_str(&json).unwrap();
        assert!(matches!(back, HostRequest::Transcribe { .. }));
    }
}
