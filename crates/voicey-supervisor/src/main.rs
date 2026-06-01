//! macOS/Linux supervisor: JSONL on stdin/stdout for host control.
//! Spawns worker binaries whose paths are supplied via environment variables.

mod process;

use std::io::{BufRead, Write};
use voicey_protocol::{HostRequest, HostResponse, PROTOCOL_VERSION};

fn main() {
    eprintln!("voicey-supervisor protocol v{PROTOCOL_VERSION}");
    if let Err(error) = run(std::io::stdin().lock(), std::io::stdout()) {
        eprintln!("voicey-supervisor fatal: {error}");
        std::process::exit(1);
    }
}

fn run(mut input: impl BufRead, mut output: impl Write) -> std::io::Result<()> {
    let mut workers = process::WorkerProcesses::new();
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
        let response = handle_request(trimmed, &mut workers);
        let json = serde_json::to_string(&response).map_err(|e| {
            std::io::Error::new(std::io::ErrorKind::InvalidData, e)
        })?;
        writeln!(output, "{json}")?;
        output.flush()?;
    }
    workers.shutdown_all();
    Ok(())
}

fn handle_request(line: &str, workers: &mut process::WorkerProcesses) -> HostResponse {
    let request: HostRequest = match serde_json::from_str(line) {
        Ok(value) => value,
        Err(error) => {
            return HostResponse::Error {
                id: String::new(),
                message: format!("invalid request: {error}"),
            };
        }
    };

    match request {
        HostRequest::Ping { id } => HostResponse::Pong { id },
        HostRequest::PrewarmInfer { id, model_id } | HostRequest::LoadModel { id, model_id } => {
            match workers.infer_load_model(&model_id) {
                Ok(()) => HostResponse::InferReady { id, model_id },
                Err(message) => HostResponse::Error { id, message },
            }
        }
        HostRequest::PrewarmCapture { id } => match workers.capture_prewarm() {
            Ok(()) => HostResponse::CaptureReady { id },
            Err(message) => HostResponse::Error { id, message },
        },
        HostRequest::PrewarmAllWorkers { id, model_id } => {
            let capture = workers.capture_prewarm();
            let infer = workers.infer_load_model(&model_id);
            match (capture, infer) {
                (Ok(()), Ok(())) => HostResponse::Ready { id },
                (Err(message), _) | (_, Err(message)) => HostResponse::Error { id, message },
            }
        }
        HostRequest::UnloadModel { id } => match workers.infer_unload() {
            Ok(()) => HostResponse::Ready { id },
            Err(message) => HostResponse::Error { id, message },
        },
        HostRequest::Transcribe {
            id,
            model_id,
            sample_rate,
            shm_name,
            sample_count,
            sample_offset,
            decoder_context,
            language,
        } => {
            use process::InferTranscribeParams;
            match workers.infer_transcribe(&InferTranscribeParams {
                model_id: &model_id,
                sample_rate,
                shm_name: &shm_name,
                sample_count,
                sample_offset,
                decoder_context: decoder_context.as_deref(),
                language: language.as_deref(),
            }) {
                Ok(result) => HostResponse::TranscribeResult {
                    id,
                    ok: true,
                    raw_text: Some(result.raw_text),
                    language: Some(result.language),
                    processing_seconds: Some(result.processing_seconds),
                    audio_seconds: Some(result.audio_seconds),
                    error: None,
                },
                Err(message) => HostResponse::TranscribeResult {
                    id,
                    ok: false,
                    raw_text: None,
                    language: None,
                    processing_seconds: None,
                    audio_seconds: None,
                    error: Some(message),
                },
            }
        }
        HostRequest::DownloadModel {
            id,
            model_id,
            destination_root,
        } => match workers.fetch_download_model(&model_id, &destination_root) {
            Ok(path) => HostResponse::DownloadComplete {
                id,
                model_id,
                path,
            },
            Err(message) => HostResponse::DownloadFailed {
                id,
                model_id,
                error: message,
            },
        },
        HostRequest::CancelDownload { id, model_id: _ } => HostResponse::Ready { id },
        HostRequest::StartCapture { id } => HostResponse::CaptureReady { id },
        HostRequest::StopCapture { id } => HostResponse::Error {
            id,
            message: "StopCapture not implemented in rust supervisor; use Swift host capture".into(),
        },
        HostRequest::CaptureFixture { id, duration_seconds } => {
            match workers.capture_fixture(duration_seconds) {
                Ok((shm_name, sample_count, sample_rate)) => HostResponse::CaptureStopped {
                    id,
                    shm_name,
                    sample_count,
                    sample_rate,
                },
                Err(message) => HostResponse::Error { id, message },
            }
        }
    }
}
