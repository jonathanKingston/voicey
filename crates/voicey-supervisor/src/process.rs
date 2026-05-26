use serde::Deserialize;
use std::io::{BufRead, BufReader, Write};
use std::process::{Child, Command, Stdio};
use voicey_protocol::{InferWorkerRequest, InferWorkerResponse};

pub struct WorkerProcesses {
    infer: Option<ManagedWorker>,
    capture: Option<ManagedWorker>,
    fetch: Option<ManagedWorker>,
}

struct ManagedWorker {
    _child: Child,
    stdin: std::process::ChildStdin,
    stdout: BufReader<std::process::ChildStdout>,
}

pub struct TranscribeResult {
    pub raw_text: String,
    pub language: String,
    pub processing_seconds: f64,
    pub audio_seconds: f64,
}

#[derive(Debug, Deserialize)]
struct CaptureFixtureResponse {
    #[serde(rename = "type")]
    kind: String,
    id: String,
    ok: bool,
    shm_name: Option<String>,
    sample_count: Option<usize>,
    sample_rate: Option<u32>,
    error: Option<String>,
}

impl WorkerProcesses {
    pub fn new() -> Self {
        Self {
            infer: None,
            capture: None,
            fetch: None,
        }
    }

    pub fn shutdown_all(&mut self) {
        self.infer = None;
        self.capture = None;
        self.fetch = None;
    }

    pub fn infer_load_model(&mut self, model_id: &str) -> Result<(), String> {
        let worker = self.ensure_infer()?;
        let response = write_infer(worker, InferWorkerRequest::LoadModel {
            id: new_id(),
            model_id: model_id.to_string(),
        })?;
        match response {
            InferWorkerResponse::InferReady { .. } | InferWorkerResponse::Ready { .. } => Ok(()),
            InferWorkerResponse::Error { message, .. } => Err(message),
            other => Err(format!("unexpected infer load response: {other:?}")),
        }
    }

    pub fn infer_unload(&mut self) -> Result<(), String> {
        let worker = self.ensure_infer()?;
        let _ = write_infer(
            worker,
            InferWorkerRequest::UnloadModel { id: new_id() },
        )?;
        Ok(())
    }

    pub fn infer_transcribe(
        &mut self,
        model_id: &str,
        sample_rate: u32,
        shm_name: &str,
        sample_count: usize,
    ) -> Result<TranscribeResult, String> {
        let worker = self.ensure_infer()?;
        let response = write_infer(
            worker,
            InferWorkerRequest::Transcribe {
                id: new_id(),
                model_id: model_id.to_string(),
                sample_rate,
                shm_name: shm_name.to_string(),
                sample_count,
            },
        )?;
        match response {
            InferWorkerResponse::TranscribeResult {
                ok: true,
                raw_text,
                language,
                processing_seconds,
                audio_seconds,
                ..
            } => Ok(TranscribeResult {
                raw_text: raw_text.unwrap_or_default(),
                language: language.unwrap_or_else(|| "auto".into()),
                processing_seconds: processing_seconds.unwrap_or(0.0),
                audio_seconds: audio_seconds.unwrap_or(0.0),
            }),
            InferWorkerResponse::TranscribeResult {
                error: Some(message), ..
            } => Err(message),
            InferWorkerResponse::Error { message, .. } => Err(message),
            other => Err(format!("unexpected infer transcribe response: {other:?}")),
        }
    }

    pub fn capture_prewarm(&mut self) -> Result<(), String> {
        let worker = self.ensure_capture()?;
        let line = serde_json::json!({"type":"prewarm","id":new_id()}).to_string();
        let response = write_capture_line(worker, &line)?;
        if response.kind == "capture_ready" {
            Ok(())
        } else {
            Err(response.error.unwrap_or_else(|| "capture prewarm failed".into()))
        }
    }

    pub fn capture_fixture(
        &mut self,
        duration_seconds: f64,
    ) -> Result<(String, usize, u32), String> {
        let worker = self.ensure_capture()?;
        let line = serde_json::json!({
            "type":"record_fixture",
            "id": new_id(),
            "duration_seconds": duration_seconds
        })
        .to_string();
        let response: CaptureFixtureResponse = write_capture_json(worker, &line)?;
        if !response.ok {
            return Err(response.error.unwrap_or_else(|| "capture fixture failed".into()));
        }
        Ok((
            response.shm_name.ok_or_else(|| "missing shm".to_string())?,
            response.sample_count.unwrap_or(0),
            response.sample_rate.unwrap_or(16_000),
        ))
    }

    pub fn fetch_download_placeholder(
        &mut self,
        model_id: &str,
        destination_root: &str,
    ) -> Result<String, String> {
        let _worker = self.ensure_fetch()?;
        let path = std::path::PathBuf::from(destination_root).join(model_id);
        std::fs::create_dir_all(&path).map_err(|e| e.to_string())?;
        Ok(path.display().to_string())
    }

    fn ensure_infer(&mut self) -> Result<&mut ManagedWorker, String> {
        if self.infer.is_none() {
            self.infer = Some(spawn_worker(env_path("VOICEY_INFER_WORKER")?)?);
        }
        self.infer.as_mut().ok_or_else(|| "infer worker missing".to_string())
    }

    fn ensure_capture(&mut self) -> Result<&mut ManagedWorker, String> {
        if self.capture.is_none() {
            self.capture = Some(spawn_worker(env_path("VOICEY_CAPTURE_WORKER")?)?);
        }
        self.capture
            .as_mut()
            .ok_or_else(|| "capture worker missing".to_string())
    }

    fn ensure_fetch(&mut self) -> Result<&mut ManagedWorker, String> {
        if self.fetch.is_none() {
            self.fetch = Some(spawn_worker(env_path("VOICEY_FETCH_WORKER")?)?);
        }
        self.fetch.as_mut().ok_or_else(|| "fetch worker missing".to_string())
    }
}

#[derive(Debug, Deserialize)]
struct CaptureLineResponse {
    #[serde(rename = "type")]
    kind: String,
    error: Option<String>,
}

fn spawn_worker(path: String) -> Result<ManagedWorker, String> {
    let mut child = Command::new(&path)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .map_err(|e| format!("spawn {path}: {e}"))?;
    let stdin = child.stdin.take().ok_or_else(|| "stdin missing".to_string())?;
    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| "stdout missing".to_string())?;
    Ok(ManagedWorker {
        _child: child,
        stdin,
        stdout: BufReader::new(stdout),
    })
}

fn write_infer(
    worker: &mut ManagedWorker,
    request: InferWorkerRequest,
) -> Result<InferWorkerResponse, String> {
    let json = serde_json::to_string(&request).map_err(|e| e.to_string())?;
    writeln!(worker.stdin, "{json}").map_err(|e| e.to_string())?;
    worker.stdin.flush().map_err(|e| e.to_string())?;
    read_infer_response(worker)
}

fn read_infer_response(worker: &mut ManagedWorker) -> Result<InferWorkerResponse, String> {
    let mut line = String::new();
    worker.stdout.read_line(&mut line).map_err(|e| e.to_string())?;
    serde_json::from_str(line.trim()).map_err(|e| e.to_string())
}

fn write_capture_line(worker: &mut ManagedWorker, line: &str) -> Result<CaptureLineResponse, String> {
    write_capture_json(worker, line)
}

fn write_capture_json<T: for<'de> Deserialize<'de>>(
    worker: &mut ManagedWorker,
    line: &str,
) -> Result<T, String> {
    writeln!(worker.stdin, "{line}").map_err(|e| e.to_string())?;
    worker.stdin.flush().map_err(|e| e.to_string())?;
    let mut response_line = String::new();
    worker
        .stdout
        .read_line(&mut response_line)
        .map_err(|e| e.to_string())?;
    serde_json::from_str(response_line.trim()).map_err(|e| e.to_string())
}

fn env_path(key: &str) -> Result<String, String> {
    std::env::var(key).map_err(|_| format!("missing environment variable {key}"))
}

fn new_id() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    format!("{nanos}")
}
