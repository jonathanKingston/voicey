use serde::Deserialize;
use std::io::{BufRead, BufReader, Write};
use std::process::{Child, Command, Stdio};
use std::time::Duration;
use voicey_protocol::{
    hugging_face_repo_id, qwen_weight_list_patterns, InferWorkerRequest, InferWorkerResponse,
    FETCH_STAGING_CONTAINER_PREFIX, FETCH_STAGING_DIRECTORY_NAME,
};

const DEFAULT_WORKER_TIMEOUT: Duration = Duration::from_secs(120);
const LOAD_MODEL_TIMEOUT: Duration = Duration::from_secs(600);
const FETCH_DOWNLOAD_TIMEOUT: Duration = Duration::from_secs(7200);

enum WorkerReadError {
    Timeout,
    Io(String),
}

fn worker_request_timeout(default: Duration) -> Duration {
    match std::env::var("VOICEY_WORKER_REQUEST_TIMEOUT_MS") {
        Ok(raw) => raw
            .trim()
            .parse::<u64>()
            .map(Duration::from_millis)
            .unwrap_or(default),
        Err(_) => default,
    }
}

fn transcribe_timeout(sample_count: usize, sample_rate: u32) -> Duration {
    let audio_seconds = sample_count as f64 / f64::from(sample_rate.max(1));
    let seconds = (audio_seconds * 4.0 + 60.0).clamp(120.0, 3600.0);
    worker_request_timeout(Duration::from_secs_f64(seconds))
}

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

#[derive(Debug)]
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
        self.ensure_infer()?;
        let response = write_infer(
            &mut self.infer,
            InferWorkerRequest::LoadModel {
                id: new_id(),
                model_id: model_id.to_string(),
            },
            worker_request_timeout(LOAD_MODEL_TIMEOUT),
        )?;
        match response {
            InferWorkerResponse::InferReady { .. } | InferWorkerResponse::Ready { .. } => Ok(()),
            InferWorkerResponse::Error { message, .. } => Err(message),
            other => Err(format!("unexpected infer load response: {other:?}")),
        }
    }

    pub fn infer_unload(&mut self) -> Result<(), String> {
        self.ensure_infer()?;
        let _ = write_infer(
            &mut self.infer,
            InferWorkerRequest::UnloadModel { id: new_id() },
            worker_request_timeout(DEFAULT_WORKER_TIMEOUT),
        )?;
        Ok(())
    }

    pub fn infer_transcribe(
        &mut self,
        model_id: &str,
        sample_rate: u32,
        shm_name: &str,
        sample_count: usize,
        sample_offset: usize,
        decoder_context: Option<&str>,
    ) -> Result<TranscribeResult, String> {
        self.ensure_infer()?;
        let timeout = transcribe_timeout(sample_count, sample_rate);
        let response = write_infer(
            &mut self.infer,
            InferWorkerRequest::Transcribe {
                id: new_id(),
                model_id: model_id.to_string(),
                sample_rate,
                shm_name: shm_name.to_string(),
                sample_count,
                sample_offset,
                decoder_context: decoder_context.map(str::to_string),
            },
            timeout,
        )?;
        transcribe_result_from_infer_response(response)
    }

    pub fn capture_prewarm(&mut self) -> Result<(), String> {
        self.ensure_capture()?;
        let line = serde_json::json!({"type":"prewarm","id":new_id()}).to_string();
        let response = write_capture_line(
            &mut self.capture,
            &line,
            worker_request_timeout(DEFAULT_WORKER_TIMEOUT),
        )?;
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
        self.ensure_capture()?;
        let line = serde_json::json!({
            "type":"record_fixture",
            "id": new_id(),
            "duration_seconds": duration_seconds
        })
        .to_string();
        let response: CaptureFixtureResponse = write_capture_json(
            &mut self.capture,
            &line,
            worker_request_timeout(DEFAULT_WORKER_TIMEOUT),
        )?;
        capture_fixture_from_response(response)
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
        self.ensure_fetch()?;
        let payload = serde_json::json!({
            "type": "list_model_files",
            "id": new_id(),
            "model_id": hf_model_id,
            "revision": "main",
            "patterns": patterns,
        });
        let response: FetchListFilesResponse = write_fetch_json(
            &mut self.fetch,
            &payload.to_string(),
            worker_request_timeout(DEFAULT_WORKER_TIMEOUT),
        )?;
        match response.kind.as_str() {
            "listed_model_files" => response
                .files
                .ok_or_else(|| "missing files in list response".to_string()),
            _ => Err(response
                .message
                .unwrap_or_else(|| "fetch list_model_files failed".to_string())),
        }
    }

    fn ensure_infer(&mut self) -> Result<(), String> {
        if self.infer.is_none() {
            let path = env_path("VOICEY_INFER_WORKER")?;
            self.infer = Some(spawn_worker(&path, &["infer-worker"])?);
        }
        Ok(())
    }

    fn ensure_capture(&mut self) -> Result<(), String> {
        if self.capture.is_none() {
            let path = env_path("VOICEY_CAPTURE_WORKER")?;
            self.capture = Some(spawn_worker(&path, &[])?);
        }
        Ok(())
    }

    fn ensure_fetch(&mut self) -> Result<(), String> {
        if self.fetch.is_none() {
            let path = env_path("VOICEY_FETCH_WORKER")?;
            self.fetch = Some(spawn_worker(&path, &[])?);
        }
        Ok(())
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
        self.ensure_fetch()?;
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
        let response: FetchLineResponse = write_fetch_json(
            &mut self.fetch,
            &payload.to_string(),
            worker_request_timeout(FETCH_DOWNLOAD_TIMEOUT),
        )?;
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
    slot: &mut Option<ManagedWorker>,
    request: InferWorkerRequest,
    timeout: Duration,
) -> Result<InferWorkerResponse, String> {
    let worker = slot
        .as_mut()
        .ok_or_else(|| "infer worker missing".to_string())?;
    let json = serde_json::to_string(&request).map_err(|e| e.to_string())?;
    writeln!(worker.stdin, "{json}").map_err(|e| e.to_string())?;
    worker.stdin.flush().map_err(|e| e.to_string())?;
    let line = read_worker_line(worker, timeout).map_err(|error| map_read_error(slot, error))?;
    serde_json::from_str(line.trim()).map_err(|e| e.to_string())
}

fn write_capture_line(
    slot: &mut Option<ManagedWorker>,
    line: &str,
    timeout: Duration,
) -> Result<CaptureLineResponse, String> {
    write_capture_json(slot, line, timeout)
}

fn write_capture_json<T: for<'de> Deserialize<'de>>(
    slot: &mut Option<ManagedWorker>,
    line: &str,
    timeout: Duration,
) -> Result<T, String> {
    let worker = slot
        .as_mut()
        .ok_or_else(|| "capture worker missing".to_string())?;
    writeln!(worker.stdin, "{line}").map_err(|e| e.to_string())?;
    worker.stdin.flush().map_err(|e| e.to_string())?;
    let response_line =
        read_worker_line(worker, timeout).map_err(|error| map_read_error(slot, error))?;
    serde_json::from_str(response_line.trim()).map_err(|e| e.to_string())
}

fn write_fetch_json<T: for<'de> Deserialize<'de>>(
    slot: &mut Option<ManagedWorker>,
    line: &str,
    timeout: Duration,
) -> Result<T, String> {
    let worker = slot
        .as_mut()
        .ok_or_else(|| "fetch worker missing".to_string())?;
    writeln!(worker.stdin, "{line}").map_err(|e| e.to_string())?;
    worker.stdin.flush().map_err(|e| e.to_string())?;
    let response_line =
        read_worker_line(worker, timeout).map_err(|error| map_read_error(slot, error))?;
    serde_json::from_str(response_line.trim()).map_err(|e| e.to_string())
}

fn map_read_error(slot: &mut Option<ManagedWorker>, error: WorkerReadError) -> String {
    *slot = None;
    match error {
        WorkerReadError::Timeout => "worker request timed out".to_string(),
        WorkerReadError::Io(message) => message,
    }
}

#[cfg(unix)]
fn read_worker_line(worker: &mut ManagedWorker, timeout: Duration) -> Result<String, WorkerReadError> {
    use std::os::unix::io::AsRawFd;
    use std::time::Instant;

    let fd = worker.stdout.get_ref().as_raw_fd();
    let deadline = Instant::now() + timeout;

    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            let _ = worker._child.kill();
            return Err(WorkerReadError::Timeout);
        }

        let mut poll_fd = libc::pollfd {
            fd,
            events: libc::POLLIN,
            revents: 0,
        };
        let poll_ms = i32::try_from(remaining.as_millis().min(i32::MAX as u128))
            .unwrap_or(i32::MAX);
        let poll_result = unsafe { libc::poll(&mut poll_fd, 1, poll_ms) };
        if poll_result == 0 {
            let _ = worker._child.kill();
            return Err(WorkerReadError::Timeout);
        }
        if poll_result < 0 {
            return Err(WorkerReadError::Io(std::io::Error::last_os_error().to_string()));
        }
        if poll_fd.revents & (libc::POLLIN | libc::POLLHUP | libc::POLLERR) != 0 {
            let mut line = String::new();
            return match worker.stdout.read_line(&mut line) {
                Ok(0) => Err(WorkerReadError::Io("worker stdout closed".into())),
                Ok(_) => Ok(line),
                Err(error) => Err(WorkerReadError::Io(error.to_string())),
            };
        }
    }
}

#[cfg(not(unix))]
fn read_worker_line(worker: &mut ManagedWorker, _timeout: Duration) -> Result<String, WorkerReadError> {
    let mut line = String::new();
    worker
        .stdout
        .read_line(&mut line)
        .map_err(|error| WorkerReadError::Io(error.to_string()))?;
    if line.is_empty() {
        return Err(WorkerReadError::Io("worker stdout closed".into()));
    }
    Ok(line)
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

fn transcribe_result_from_infer_response(
    response: InferWorkerResponse,
) -> Result<TranscribeResult, String> {
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

fn capture_fixture_from_response(
    response: CaptureFixtureResponse,
) -> Result<(String, usize, u32), String> {
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

#[cfg(test)]
mod tests {
    use super::*;
    use voicey_protocol::InferWorkerResponse;

    #[test]
    fn transcribe_result_maps_success_with_defaults() {
        let response = InferWorkerResponse::TranscribeResult {
            id: "tx-1".into(),
            ok: true,
            raw_text: Some("hello".into()),
            language: None,
            processing_seconds: Some(0.5),
            audio_seconds: Some(1.0),
            error: None,
        };
        let result = transcribe_result_from_infer_response(response).expect("ok");
        assert_eq!(result.raw_text, "hello");
        assert_eq!(result.language, "auto");
        assert!((result.processing_seconds - 0.5).abs() < f64::EPSILON);
        assert!((result.audio_seconds - 1.0).abs() < f64::EPSILON);
    }

    #[test]
    fn transcribe_result_surfaces_worker_error_message() {
        let response = InferWorkerResponse::TranscribeResult {
            id: "tx-2".into(),
            ok: false,
            raw_text: None,
            language: None,
            processing_seconds: None,
            audio_seconds: None,
            error: Some("stub failure".into()),
        };
        let error = transcribe_result_from_infer_response(response).unwrap_err();
        assert_eq!(error, "stub failure");
    }

    #[test]
    fn transcribe_result_rejects_unexpected_variant() {
        let response = InferWorkerResponse::Pong { id: "pong".into() };
        let error = transcribe_result_from_infer_response(response).unwrap_err();
        assert!(error.contains("unexpected infer transcribe response"));
    }

    #[test]
    fn capture_fixture_requires_shm_when_ok() {
        let response = CaptureFixtureResponse {
            kind: "capture_stopped".into(),
            id: "cap-1".into(),
            ok: true,
            shm_name: None,
            sample_count: Some(100),
            sample_rate: Some(16_000),
            error: None,
        };
        let error = capture_fixture_from_response(response).unwrap_err();
        assert_eq!(error, "missing shm");
    }

    #[test]
    fn capture_fixture_returns_metadata_when_ok() {
        let response = CaptureFixtureResponse {
            kind: "capture_stopped".into(),
            id: "cap-2".into(),
            ok: true,
            shm_name: Some("/voicey-test".into()),
            sample_count: Some(320),
            sample_rate: Some(48_000),
            error: None,
        };
        let (shm, count, rate) = capture_fixture_from_response(response).expect("ok");
        assert_eq!(shm, "/voicey-test");
        assert_eq!(count, 320);
        assert_eq!(rate, 48_000);
    }

    #[test]
    fn new_id_values_are_unique() {
        let first = new_id();
        let second = new_id();
        assert_ne!(first, second);
        assert!(!first.is_empty());
    }
}
