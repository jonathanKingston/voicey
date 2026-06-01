//! Black-box tests: spawn `voicey-supervisor` with stub workers via env vars.

use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::{Mutex, OnceLock};
use voicey_protocol::{HostRequest, HostResponse};

fn debug_target_dir() -> PathBuf {
    let mut path = std::env::current_exe().expect("current_exe");
    path.pop(); // deps
    path.pop(); // debug
    path
}

fn binary_path(env_key: &str, file_name: &str) -> PathBuf {
    if let Ok(path) = std::env::var(env_key) {
        return PathBuf::from(path);
    }
    debug_target_dir().join(file_name)
}

fn supervisor_bin() -> PathBuf {
    binary_path("CARGO_BIN_EXE_voicey_supervisor", "voicey-supervisor")
}

fn infer_stub_bin() -> PathBuf {
    binary_path("CARGO_BIN_EXE_voicey_infer_stub", "voicey-infer-stub")
}

fn capture_stub_bin() -> PathBuf {
    binary_path("CARGO_BIN_EXE_voicey_capture_stub", "voicey-capture-stub")
}

fn fetch_stub_bin() -> PathBuf {
    binary_path("CARGO_BIN_EXE_voicey_fetch_stub", "voicey-fetch-stub")
}

fn assert_bins_exist() {
    for path in [
        supervisor_bin(),
        infer_stub_bin(),
        capture_stub_bin(),
        fetch_stub_bin(),
    ] {
        assert!(
            path.exists(),
            "missing test binary {} (run cargo test -p voicey-supervisor)",
            path.display()
        );
    }
}

struct SupervisorSession {
    child: Child,
    stdin: std::process::ChildStdin,
    stdout: BufReader<std::process::ChildStdout>,
}

impl SupervisorSession {
    fn spawn(extra_infer_env: &[(&str, &str)]) -> Self {
        assert_bins_exist();
        static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
        let _guard = LOCK.get_or_init(|| Mutex::new(())).lock().expect("test lock");

        let mut command = Command::new(supervisor_bin());
        command
            .env("VOICEY_INFER_WORKER", infer_stub_bin())
            .env("VOICEY_CAPTURE_WORKER", capture_stub_bin())
            .env("VOICEY_FETCH_WORKER", fetch_stub_bin())
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null());
        for (key, value) in extra_infer_env {
            command.env(key, value);
        }

        let mut child = command.spawn().expect("spawn voicey-supervisor");
        let stdin = child.stdin.take().expect("supervisor stdin");
        let stdout = child.stdout.take().expect("supervisor stdout");
        Self {
            child,
            stdin,
            stdout: BufReader::new(stdout),
        }
    }

    fn request_json(&mut self, line: &str) -> HostResponse {
        writeln!(self.stdin, "{line}").expect("write supervisor stdin");
        self.stdin.flush().expect("flush supervisor stdin");
        let mut response_line = String::new();
        self.stdout
            .read_line(&mut response_line)
            .expect("read supervisor stdout");
        serde_json::from_str(response_line.trim()).unwrap_or_else(|error| {
            panic!(
                "parse host response: {error}\nline={response_line:?}\nrequest={line:?}"
            )
        })
    }

    fn request(&mut self, request: &HostRequest) -> HostResponse {
        let json = serde_json::to_string(request).expect("serialize host request");
        self.request_json(&json)
    }
}

impl Drop for SupervisorSession {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn temp_download_root() -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "voicey-supervisor-test-{}",
        std::process::id()
    ));
    let _ = std::fs::create_dir_all(&dir);
    dir
}

#[test]
fn ping_returns_pong() {
    let mut session = SupervisorSession::spawn(&[]);
    let response = session.request(&HostRequest::Ping {
        id: "test-ping".into(),
    });
    assert!(matches!(response, HostResponse::Pong { id } if id == "test-ping"));
}

#[test]
fn load_model_and_transcribe_via_infer_stub() {
    let shm_name = voicey_pcm::write_f32_samples(&[0.0_f32; 512]).expect("write pcm");
    let mut session = SupervisorSession::spawn(&[]);

    let load = session.request(&HostRequest::LoadModel {
        id: "load-1".into(),
        model_id: "qwen3-asr-0.6b-6bit".into(),
    });
    assert!(
        matches!(load, HostResponse::InferReady { id, model_id } if id == "load-1" && model_id == "qwen3-asr-0.6b-6bit")
    );

    let transcribe = session.request(&HostRequest::Transcribe {
        id: "tx-1".into(),
        model_id: "qwen3-asr-0.6b-6bit".into(),
        sample_rate: 16_000,
        shm_name: shm_name.clone(),
        sample_count: 512,
        sample_offset: 0,
        decoder_context: Some("Glossary".into()),
    });
    voicey_pcm::remove(&shm_name);

    match transcribe {
        HostResponse::TranscribeResult {
            id,
            ok,
            raw_text,
            language,
            ..
        } => {
            assert_eq!(id, "tx-1");
            assert!(ok);
            assert_eq!(
                raw_text.as_deref(),
                Some("stub-transcribe:qwen3-asr-0.6b-6bit:512 ctx=Glossary")
            );
            assert_eq!(language.as_deref(), Some("en"));
        }
        other => panic!("unexpected transcribe response: {other:?}"),
    }
}

#[test]
fn prewarm_all_workers_returns_ready() {
    let mut session = SupervisorSession::spawn(&[]);
    let response = session.request(&HostRequest::PrewarmAllWorkers {
        id: "prewarm-all".into(),
        model_id: "qwen3-asr-0.6b-6bit".into(),
    });
    assert!(matches!(response, HostResponse::Ready { id } if id == "prewarm-all"));
}

#[test]
fn prewarm_capture_returns_capture_ready() {
    let mut session = SupervisorSession::spawn(&[]);
    let response = session.request(&HostRequest::PrewarmCapture {
        id: "prewarm-cap".into(),
    });
    assert!(matches!(response, HostResponse::CaptureReady { id } if id == "prewarm-cap"));
}

#[test]
fn download_model_completes_with_stub_fetch() {
    let root = temp_download_root();
    let mut session = SupervisorSession::spawn(&[]);
    let response = session.request(&HostRequest::DownloadModel {
        id: "dl-1".into(),
        model_id: "qwen3-asr-0.6b-6bit".into(),
        destination_root: root.display().to_string(),
    });
    match response {
        HostResponse::DownloadComplete { id, model_id, path } => {
            assert_eq!(id, "dl-1");
            assert_eq!(model_id, "qwen3-asr-0.6b-6bit");
            let model_dir = Path::new(&path);
            assert!(model_dir.is_dir(), "model dir missing at {path}");
            assert!(
                model_dir.join("config.json").is_file(),
                "config.json not promoted"
            );
            assert!(
                model_dir.join("model.safetensors").is_file(),
                "model.safetensors not promoted"
            );
        }
        other => panic!("unexpected download response: {other:?}"),
    }
}

#[test]
fn cancel_download_returns_ready() {
    let mut session = SupervisorSession::spawn(&[]);
    let response = session.request(&HostRequest::CancelDownload {
        id: "cancel-1".into(),
        model_id: "qwen3-asr-0.6b-6bit".into(),
    });
    assert!(matches!(response, HostResponse::Ready { id } if id == "cancel-1"));
}

#[test]
fn capture_fixture_returns_capture_stopped() {
    let mut session = SupervisorSession::spawn(&[]);
    let response = session.request(&HostRequest::CaptureFixture {
        id: "cap-fix-1".into(),
        duration_seconds: 0.1,
    });
    match response {
        HostResponse::CaptureStopped {
            id,
            shm_name,
            sample_count,
            sample_rate,
        } => {
            assert_eq!(id, "cap-fix-1");
            assert!(shm_name.starts_with(voicey_pcm::NAME_PREFIX));
            assert!(sample_count > 0);
            assert_eq!(sample_rate, 16_000);
            voicey_pcm::remove(&shm_name);
        }
        other => panic!("unexpected capture_fixture response: {other:?}"),
    }
}

/// Phase 1 pass-through: capture worker PCM file is forwarded to infer without host rewrite.
#[test]
fn capture_fixture_then_transcribe_uses_capture_shm() {
    const MODEL_ID: &str = "qwen3-asr-0.6b-6bit";
    let mut session = SupervisorSession::spawn(&[]);

    let capture = session.request(&HostRequest::CaptureFixture {
        id: "cap-tx-1".into(),
        duration_seconds: 0.05,
    });
    let (shm_name, sample_count) = match capture {
        HostResponse::CaptureStopped {
            shm_name,
            sample_count,
            ..
        } => (shm_name, sample_count),
        other => panic!("expected capture_stopped, got {other:?}"),
    };

    let load = session.request(&HostRequest::LoadModel {
        id: "load-cap-tx".into(),
        model_id: MODEL_ID.into(),
    });
    assert!(
        matches!(load, HostResponse::InferReady { .. }),
        "expected infer_ready, got {load:?}"
    );

    let transcribe = session.request(&HostRequest::Transcribe {
        id: "tx-cap-1".into(),
        model_id: MODEL_ID.into(),
        sample_rate: 16_000,
        shm_name: shm_name.clone(),
        sample_count,
        sample_offset: 0,
        decoder_context: None,
    });
    voicey_pcm::remove(&shm_name);

    match transcribe {
        HostResponse::TranscribeResult {
            id,
            ok,
            raw_text,
            audio_seconds,
            ..
        } => {
            assert_eq!(id, "tx-cap-1");
            assert!(ok);
            assert_eq!(
                raw_text.as_deref(),
                Some(format!("stub-transcribe:{MODEL_ID}:{sample_count}").as_str())
            );
            let expected_seconds = sample_count as f64 / 16_000.0;
            assert!((audio_seconds.unwrap_or(0.0) - expected_seconds).abs() < 1e-6);
        }
        other => panic!("expected transcribe_result, got {other:?}"),
    }
}

#[test]
fn invalid_host_json_returns_error() {
    let mut session = SupervisorSession::spawn(&[]);
    let response = session.request_json(r#"{"type":"not_a_real_message","id":"x"}"#);
    match response {
        HostResponse::Error { message, .. } => {
            assert!(message.contains("invalid request"));
        }
        other => panic!("expected error response, got {other:?}"),
    }
}

#[test]
fn infer_worker_exit_surfaces_load_error() {
    let mut session =
        SupervisorSession::spawn(&[("VOICEY_INFER_STUB_MODE", "exit_on_first_request")]);
    let response = session.request(&HostRequest::LoadModel {
        id: "load-fail".into(),
        model_id: "qwen3-asr-0.6b-6bit".into(),
    });
    match response {
        HostResponse::Error { id, message } => {
            assert_eq!(id, "load-fail");
            assert!(
                !message.is_empty(),
                "expected non-empty worker failure message, got {message:?}"
            );
        }
        other => panic!("expected load error, got {other:?}"),
    }
}

#[test]
fn infer_stub_exit_on_start_prevents_worker_use() {
    let mut session = SupervisorSession::spawn(&[("VOICEY_INFER_STUB_MODE", "exit_on_start")]);
    let response = session.request(&HostRequest::LoadModel {
        id: "load-dead".into(),
        model_id: "qwen3-asr-0.6b-6bit".into(),
    });
    assert!(
        matches!(response, HostResponse::Error { .. }),
        "expected error when infer worker died on start, got {response:?}"
    );
}

#[test]
fn transcribe_with_sample_offset_uses_pcm_slice() {
    let samples: Vec<f32> = (0..128).map(|index| index as f32).collect();
    let shm_name = voicey_pcm::write_f32_samples(&samples).expect("write pcm");
    let mut session = SupervisorSession::spawn(&[]);

    let _ = session.request(&HostRequest::LoadModel {
        id: "load-slice".into(),
        model_id: "qwen3-asr-0.6b-6bit".into(),
    });

    let transcribe = session.request(&HostRequest::Transcribe {
        id: "tx-slice".into(),
        model_id: "qwen3-asr-0.6b-6bit".into(),
        sample_rate: 16_000,
        shm_name: shm_name.clone(),
        sample_count: 32,
        sample_offset: 16,
        decoder_context: None,
    });
    voicey_pcm::remove(&shm_name);

    match transcribe {
        HostResponse::TranscribeResult {
            id,
            ok,
            raw_text,
            audio_seconds,
            ..
        } => {
            assert_eq!(id, "tx-slice");
            assert!(ok);
            assert_eq!(raw_text.as_deref(), Some("stub-transcribe:qwen3-asr-0.6b-6bit:32"));
            assert!((audio_seconds.unwrap_or(0.0) - 0.002).abs() < 1e-6);
        }
        other => panic!("expected transcribe_result, got {other:?}"),
    }
}

#[test]
fn infer_stub_fail_transcribe_returns_transcribe_error() {
    let shm_name = voicey_pcm::write_f32_samples(&[0.0_f32; 64]).expect("write pcm");
    let mut session = SupervisorSession::spawn(&[("VOICEY_INFER_STUB_MODE", "fail_transcribe")]);

    let _ = session.request(&HostRequest::LoadModel {
        id: "load-2".into(),
        model_id: "qwen3-asr-0.6b-6bit".into(),
    });

    let response = session.request(&HostRequest::Transcribe {
        id: "tx-fail".into(),
        model_id: "qwen3-asr-0.6b-6bit".into(),
        sample_rate: 16_000,
        shm_name: shm_name.clone(),
        sample_count: 64,
        sample_offset: 0,
        decoder_context: None,
    });
    voicey_pcm::remove(&shm_name);

    match response {
        HostResponse::TranscribeResult { id, ok, error, .. } => {
            assert_eq!(id, "tx-fail");
            assert!(!ok);
            assert_eq!(error.as_deref(), Some("stub: transcribe forced failure"));
        }
        other => panic!("expected transcribe_result error, got {other:?}"),
    }
}

#[test]
fn infer_stub_malformed_json_line_surfaces_transcribe_error() {
    let shm_name = voicey_pcm::write_f32_samples(&[0.0_f32; 32]).expect("write pcm");
    let mut session = SupervisorSession::spawn(&[("VOICEY_INFER_STUB_MODE", "malformed_response")]);

    let _ = session.request(&HostRequest::LoadModel {
        id: "load-3".into(),
        model_id: "qwen3-asr-0.6b-6bit".into(),
    });

    let response = session.request(&HostRequest::Transcribe {
        id: "tx-malformed".into(),
        model_id: "qwen3-asr-0.6b-6bit".into(),
        sample_rate: 16_000,
        shm_name: shm_name.clone(),
        sample_count: 32,
        sample_offset: 0,
        decoder_context: None,
    });
    voicey_pcm::remove(&shm_name);

    match response {
        HostResponse::TranscribeResult { id, ok, error, .. } => {
            assert_eq!(id, "tx-malformed");
            assert!(!ok);
            assert!(error.is_some());
        }
        other => panic!("expected transcribe_result error, got {other:?}"),
    }
}

#[test]
fn infer_stub_hang_on_request_times_out() {
    let mut session = SupervisorSession::spawn(&[
        ("VOICEY_INFER_STUB_MODE", "hang_on_request"),
        ("VOICEY_WORKER_REQUEST_TIMEOUT_MS", "500"),
    ]);
    let response = session.request(&HostRequest::LoadModel {
        id: "load-timeout".into(),
        model_id: "qwen3-asr-0.6b-6bit".into(),
    });
    match response {
        HostResponse::Error { id, message } => {
            assert_eq!(id, "load-timeout");
            assert!(
                message.contains("timed out"),
                "expected timeout message, got {message:?}"
            );
        }
        other => panic!("expected load timeout error, got {other:?}"),
    }
}
