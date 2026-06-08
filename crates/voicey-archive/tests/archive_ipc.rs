//! JSONL IPC tests for `voicey-archive`.

use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use tempfile::tempdir;

fn archive_bin() -> PathBuf {
    if let Ok(path) = std::env::var("CARGO_BIN_EXE_voicey_archive") {
        return PathBuf::from(path);
    }
    let mut path = std::env::current_exe().expect("current_exe");
    path.pop();
    path.pop();
    path.join("voicey-archive")
}

struct ArchiveSession {
    child: Child,
    stdin: std::process::ChildStdin,
    stdout: BufReader<std::process::ChildStdout>,
}

impl ArchiveSession {
    fn spawn() -> Self {
        let mut child = Command::new(archive_bin())
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .expect("spawn voicey-archive");
        let stdin = child.stdin.take().expect("stdin");
        let stdout = child.stdout.take().expect("stdout");
        Self {
            child,
            stdin,
            stdout: BufReader::new(stdout),
        }
    }

    fn request_json(&mut self, line: &str) -> serde_json::Value {
        writeln!(self.stdin, "{line}").expect("write");
        self.stdin.flush().expect("flush");
        let mut response = String::new();
        self.stdout.read_line(&mut response).expect("read");
        serde_json::from_str(response.trim()).expect("parse response")
    }
}

impl Drop for ArchiveSession {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

#[test]
fn append_from_pcm_shm_writes_wav_and_index() {
    assert!(archive_bin().exists(), "build voicey-archive first");
    let dir = tempdir().expect("tempdir");
    let archive_root = dir.path().to_string_lossy();
    let samples = vec![0.25_f32; 800];
    let shm_name = voicey_pcm::write_f32_samples(&samples).expect("write pcm");

    let payload = serde_json::json!({
        "type": "append_utterance",
        "id": "a1",
        "archive_root": archive_root,
        "audio": {
            "source": "pcm_shm",
            "shm_name": shm_name,
            "sample_count": samples.len()
        },
        "metadata": {
            "outcome": "completed",
            "model_id": "qwen",
            "language_id": "en",
            "raw_text": "test",
            "processed_text": "Test",
            "glossary_enabled": false,
            "screen_context_enabled": false
        }
    });

    let mut session = ArchiveSession::spawn();
    let response = session.request_json(&payload.to_string());
    assert_eq!(response["type"], "archive_result");
    assert_eq!(response["ok"], true);

    let _ = voicey_pcm::remove(&shm_name);

    let index = std::fs::read_to_string(dir.path().join("index.jsonl")).expect("index");
    assert!(index.contains("Test"));
    let record: serde_json::Value = serde_json::from_str(index.lines().next().unwrap()).unwrap();
    let audio_path = dir.path().join(record["audio_path"].as_str().unwrap());
    assert!(audio_path.is_file());
    assert_eq!(record["audio_format"], "wav_f32");
    let mut reader = hound::WavReader::open(&audio_path).expect("open wav");
    assert_eq!(reader.spec().sample_format, hound::SampleFormat::Float);
    let read_back: Vec<f32> = reader
        .samples::<f32>()
        .collect::<Result<_, _>>()
        .expect("samples");
    assert_eq!(read_back, samples);
}
