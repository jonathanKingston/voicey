//! Black-box IPC tests for `voicey-capture` (no physical microphone required).
//!
//! `record_fixture` synthesizes silence when live capture is unavailable, so these
//! tests run in Linux CI without audio hardware.

use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};

fn capture_bin() -> PathBuf {
    if let Ok(path) = std::env::var("CARGO_BIN_EXE_voicey_capture") {
        return PathBuf::from(path);
    }
    let mut path = std::env::current_exe().expect("current_exe");
    path.pop(); // deps
    path.pop(); // debug
    path.join("voicey-capture")
}

fn assert_capture_bin_exists() {
    let path = capture_bin();
    assert!(
        path.exists(),
        "missing voicey-capture binary at {} (run cargo test -p voicey-capture)",
        path.display()
    );
}

struct CaptureSession {
    child: Child,
    stdin: std::process::ChildStdin,
    stdout: BufReader<std::process::ChildStdout>,
}

impl CaptureSession {
    fn spawn() -> Self {
        assert_capture_bin_exists();
        let mut child = Command::new(capture_bin())
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .expect("spawn voicey-capture");
        let stdin = child.stdin.take().expect("capture stdin");
        let stdout = child.stdout.take().expect("capture stdout");
        Self {
            child,
            stdin,
            stdout: BufReader::new(stdout),
        }
    }

    fn request_json(&mut self, line: &str) -> serde_json::Value {
        writeln!(self.stdin, "{line}").expect("write capture stdin");
        self.stdin.flush().expect("flush capture stdin");
        let mut response_line = String::new();
        self.stdout
            .read_line(&mut response_line)
            .expect("read capture stdout");
        serde_json::from_str(response_line.trim()).unwrap_or_else(|error| {
            panic!(
                "parse capture response: {error}\nline={response_line:?}\nrequest={line:?}"
            )
        })
    }
}

impl Drop for CaptureSession {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

#[test]
fn ping_returns_pong() {
    let mut session = CaptureSession::spawn();
    let response = session.request_json(r#"{"type":"ping","id":"ping-1"}"#);
    assert_eq!(response["type"], "pong");
    assert_eq!(response["id"], "ping-1");
}

#[test]
fn record_fixture_writes_readable_pcm() {
    let mut session = CaptureSession::spawn();
    let response = session.request_json(
        r#"{"type":"record_fixture","id":"fix-1","duration_seconds":0.05}"#,
    );
    assert_eq!(response["type"], "capture_fixture_result");
    assert_eq!(response["id"], "fix-1");
    assert_eq!(response["ok"], true);

    let shm_name = response["shm_name"]
        .as_str()
        .expect("shm_name")
        .to_string();
    let sample_count = response["sample_count"]
        .as_u64()
        .expect("sample_count") as usize;
    assert_eq!(response["sample_rate"], 16_000);
    assert!(shm_name.starts_with(voicey_pcm::NAME_PREFIX));
    assert_eq!(sample_count, 800, "0.05s at 16 kHz");

    let samples = voicey_pcm::read_f32_samples(&shm_name, sample_count).expect("read pcm");
    assert_eq!(samples.len(), sample_count);
    voicey_pcm::remove(&shm_name);
}

#[test]
fn record_fixture_rejects_out_of_range_duration() {
    let mut session = CaptureSession::spawn();
    let response = session.request_json(
        r#"{"type":"record_fixture","id":"fix-bad","duration_seconds":60}"#,
    );
    assert_eq!(response["type"], "capture_fixture_result");
    assert_eq!(response["ok"], false);
    assert!(response["error"].as_str().is_some());
}

#[test]
fn load_wav_file_decodes_pcm_fixture() {
    let samples = vec![0.0_f32, 0.5, -0.25, 0.125];
    let wav_path = write_test_wav(&samples, 16_000, 1);

    let mut session = CaptureSession::spawn();
    let request = format!(
        r#"{{"type":"load_wav_file","id":"wav-1","path":"{}"}}"#,
        wav_path.display()
    );
    let response = session.request_json(&request);
    assert_eq!(response["type"], "capture_fixture_result");
    assert_eq!(response["id"], "wav-1");
    assert_eq!(response["ok"], true);
    assert_eq!(response["sample_rate"], 16_000);

    let shm_name = response["shm_name"]
        .as_str()
        .expect("shm_name")
        .to_string();
    let sample_count = response["sample_count"]
        .as_u64()
        .expect("sample_count") as usize;
    assert_eq!(sample_count, samples.len());

    let read_back = voicey_pcm::read_f32_samples(&shm_name, sample_count).expect("read pcm");
    assert_eq!(read_back.len(), samples.len());
    voicey_pcm::remove(&shm_name);
    std::fs::remove_file(&wav_path).ok();
}

#[test]
fn load_wav_file_rejects_missing_path() {
    let mut session = CaptureSession::spawn();
    let response = session.request_json(
        r#"{"type":"load_wav_file","id":"wav-missing","path":"/tmp/voicey-capture-missing.wav"}"#,
    );
    assert_eq!(response["type"], "capture_fixture_result");
    assert_eq!(response["ok"], false);
    assert!(response["error"].as_str().is_some());
}

fn write_test_wav(samples: &[f32], sample_rate: u32, channels: u16) -> PathBuf {
    use hound::{SampleFormat, WavSpec, WavWriter};

    let path = std::env::temp_dir().join(format!(
        "voicey_capture_ipc_wav_{}_{}.wav",
        std::process::id(),
        samples.len()
    ));
    let spec = WavSpec {
        channels,
        sample_rate,
        bits_per_sample: 16,
        sample_format: SampleFormat::Int,
    };
    let mut writer = WavWriter::create(&path, spec).expect("create wav");
    for sample in samples {
        let scaled = (sample.clamp(-1.0, 1.0) * i16::MAX as f32) as i16;
        writer.write_sample(scaled).expect("write sample");
    }
    writer.finalize().expect("finalize wav");
    path
}

#[test]
fn invalid_request_json_returns_error() {
    let mut session = CaptureSession::spawn();
    let response = session.request_json(r#"{"type":"not_a_capture_message","id":"x"}"#);
    assert_eq!(response["type"], "error");
    assert!(
        response["message"]
            .as_str()
            .expect("message")
            .contains("invalid request")
    );
}

#[test]
fn stop_recording_without_start_returns_not_recording() {
    let mut session = CaptureSession::spawn();
    let response =
        session.request_json(r#"{"type":"stop_recording","id":"stop-1","apply_trailing_trim":false}"#);
    assert_eq!(response["type"], "capture_fixture_result");
    assert_eq!(response["ok"], false);
    let message = response["error"].as_str().expect("error message");
    assert!(
        message.contains("not recording"),
        "expected not-recording error, got {message:?}"
    );
}
