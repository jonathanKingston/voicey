use serde::Deserialize;
use std::io::{BufRead, BufReader, Write};
use std::process::{Child, Command, Stdio};
use voicey_protocol::{
    hugging_face_repo_id, qwen_weight_list_patterns, InferWorkerRequest, InferWorkerResponse,
    FETCH_STAGING_CONTAINER_PREFIX, FETCH_STAGING_DIRECTORY_NAME,
};

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
#[allow(dead_code)]
struct CaptureFixtureResponse {
    #[serde(rename = "type")]
    kind: String,
    #[allow(dead_code)]
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
        let response = write_infer(
            worker,
            InferWorkerRequest::LoadModel {
                id: new_id(),
                model_id: model_id.to_string(),
            },
        )?;
        match response {
            InferWorkerResponse::InferReady { .. } | InferWorkerResponse::Ready { .. } => Ok(()),
            InferWorkerResponse::Error { message, .. } => Err(message),
            other => Err(format!("unexpected infer load response: {other:?}")),
        }
    }

    pub fn infer_unload(&mut self) -> Result<(), String> {
        let worker = self.ensure_infer()?;
        let _ = write_infer(worker, InferWorkerRequest::UnloadModel { id: new_id() })?;
        Ok(())
    }

    pub fn infer_transcribe(
        &mut self,
        model_id: &str,
        sample_rate: u32,
        shm_name: &str,
        sample_count: usize,
        decoder_context: Option<&str>,
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
                decoder_context: decoder_context.map(str::to_string),
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
                error: Some(message),
                ..
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
            Err(response
                .error
                .unwrap_or_else(|| "capture prewarm failed".into()))
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
            return Err(response
                .error
                .unwrap_or_else(|| "capture fixture failed".into()));
        }
        Ok((
            response.shm_name.ok_or_else(|| "missing shm".to_string())?,
            response.sample_count.unwrap_or(0),
            response.sample_rate.unwrap_or(16_000),
        ))
    }

    pub fn fetch_download_model(
        &mut self,
        model_id: &str,
        destination_root: &str,
    ) -> Result<String, String> {
        use std::fs;
        use std::path::PathBuf;

        // Host `DownloadModel` uses Voicey ids; fetch worker IPC requires org/repo HF ids.
        let hf_id = hugging_face_repo_id(model_id)?;
        let files = self.fetch_list_model_files(hf_id, &qwen_weight_list_patterns())?;
        if files.is_empty() {
            return Err(format!("{model_id}: no files matched"));
        }

        let destination = PathBuf::from(destination_root);
        fs::create_dir_all(&destination).map_err(|error| error.to_string())?;

        let model_dir = destination.join(model_id);
        let staging_container = destination.join(format!(
            "{FETCH_STAGING_CONTAINER_PREFIX}{model_id}-{}",
            new_id()
        ));
        fs::create_dir_all(&staging_container).map_err(|error| error.to_string())?;

        let model_root = staging_container
            .to_str()
            .ok_or_else(|| "invalid staging container path".to_string())?;

        for relative_path in files {
            if let Err(error) =
                self.fetch_download_model_file(hf_id, &relative_path, model_root, None)
            {
                // Never leave a partial download container behind on failure.
                let _ = fs::remove_dir_all(&staging_container);
                return Err(error);
            }
        }

        let staged_model_root = staging_container.join(FETCH_STAGING_DIRECTORY_NAME);
        if !staged_model_root.is_dir() {
            let _ = fs::remove_dir_all(&staging_container);
            return Err(format!("{model_id}: staged model root missing"));
        }

        if model_dir.exists() {
            fs::remove_dir_all(&model_dir).map_err(|error| error.to_string())?;
        }
        fs::rename(&staged_model_root, &model_dir).map_err(|error| error.to_string())?;
        let _ = fs::remove_dir_all(&staging_container);

        Ok(model_dir.display().to_string())
    }

    fn fetch_list_model_files(
        &mut self,
        hf_model_id: &str,
        patterns: &[String],
    ) -> Result<Vec<String>, String> {
        let worker = self.ensure_fetch()?;
        let payload = serde_json::json!({
            "type": "list_model_files",
            "id": new_id(),
            "model_id": hf_model_id,
            "revision": "main",
            "patterns": patterns,
        });
        let response: FetchListFilesResponse =
            write_fetch_json(worker, &payload.to_string())?;
        match response.kind.as_str() {
            "listed_model_files" => response
                .files
                .ok_or_else(|| "missing files in list response".to_string()),
            _ => Err(response
                .message
                .unwrap_or_else(|| "fetch list_model_files failed".to_string())),
        }
    }

    fn ensure_infer(&mut self) -> Result<&mut ManagedWorker, String> {
        if self.infer.is_none() {
            let path = env_path("VOICEY_INFER_WORKER")?;
            self.infer = Some(spawn_worker(&path, &["infer-worker"])?);
        }
        self.infer
            .as_mut()
            .ok_or_else(|| "infer worker missing".to_string())
    }

    fn ensure_capture(&mut self) -> Result<&mut ManagedWorker, String> {
        if self.capture.is_none() {
            let path = env_path("VOICEY_CAPTURE_WORKER")?;
            self.capture = Some(spawn_worker(&path, &[])?);
        }
        self.capture
            .as_mut()
            .ok_or_else(|| "capture worker missing".to_string())
    }

    fn ensure_fetch(&mut self) -> Result<&mut ManagedWorker, String> {
        if self.fetch.is_none() {
            let path = env_path("VOICEY_FETCH_WORKER")?;
            self.fetch = Some(spawn_worker(&path, &[])?);
        }
        self.fetch
            .as_mut()
            .ok_or_else(|| "fetch worker missing".to_string())
    }
}

#[derive(Debug, Deserialize)]
struct FetchListFilesResponse {
    #[serde(rename = "type")]
    kind: String,
    files: Option<Vec<String>>,
    message: Option<String>,
}

#[derive(Debug, Deserialize)]
struct FetchLineResponse {
    #[serde(rename = "type")]
    kind: String,
    #[allow(dead_code)]
    id: String,
    message: Option<String>,
}

impl WorkerProcesses {
    pub fn fetch_download_model_file(
        &mut self,
        model_id: &str,
        relative_path: &str,
        model_root: &str,
        expected_sha256: Option<&str>,
    ) -> Result<(), String> {
        let worker = self.ensure_fetch()?;
        let mut payload = serde_json::json!({
            "type": "download_model_file",
            "id": new_id(),
            "model_id": model_id,
            "relative_path": relative_path,
            "model_root": model_root,
        });
        if let Some(hash) = expected_sha256 {
            payload["expected_sha256"] = serde_json::Value::String(hash.to_string());
        }
        let response: FetchLineResponse = write_fetch_json(worker, &payload.to_string())?;
        if response.kind == "downloaded_model_file" {
            Ok(())
        } else {
            Err(response
                .message
                .unwrap_or_else(|| "fetch download failed".into()))
        }
    }
}

#[derive(Debug, Deserialize)]
struct CaptureLineResponse {
    #[serde(rename = "type")]
    kind: String,
    error: Option<String>,
}

fn spawn_worker(path: &str, args: &[&str]) -> Result<ManagedWorker, String> {
    let mut command = Command::new(path);
    command.args(args);
    command
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit());
    let mut child = command.spawn().map_err(|e| format!("spawn {path}: {e}"))?;
    let stdin = child
        .stdin
        .take()
        .ok_or_else(|| "stdin missing".to_string())?;
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
    worker
        .stdout
        .read_line(&mut line)
        .map_err(|e| e.to_string())?;
    serde_json::from_str(line.trim()).map_err(|e| e.to_string())
}

fn write_capture_line(
    worker: &mut ManagedWorker,
    line: &str,
) -> Result<CaptureLineResponse, String> {
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

fn write_fetch_json<T: for<'de> Deserialize<'de>>(
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
