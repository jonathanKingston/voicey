//! End-to-end coverage for the supervisor `DownloadModel` host request.
//!
//! Drives the real `voicey-supervisor` binary over JSONL stdin/stdout against a
//! stub fetch worker that mirrors the `voicey-fetch` IPC contract. This exercises
//! the full list -> per-file download -> staged-tree promote round-trip and locks
//! in two invariants that previously regressed:
//!   1. the supervisor forwards a Hugging Face `org/repo` id (not the raw Voicey
//!      slug) to the fetch worker, and
//!   2. the staged tree is promoted into `<destination_root>/<voicey_model_id>`.

#![cfg(unix)]

use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::PermissionsExt;
use std::process::{Command, Stdio};

/// Stub fetch worker. Asserts it only ever receives HF `org/repo` ids and writes
/// stub files into the staging subdirectory the supervisor later promotes.
const MOCK_FETCH_WORKER: &str = r#"#!/usr/bin/env python3
import sys, json, os

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    req = json.loads(line)
    kind = req.get("type")
    rid = req.get("id", "")
    if kind == "list_model_files":
        assert "/" in req["model_id"], "expected HF org/repo id, got %r" % req["model_id"]
        print(json.dumps({
            "type": "listed_model_files",
            "id": rid,
            "files": ["config.json", "model.safetensors"],
        }), flush=True)
    elif kind == "download_model_file":
        assert "/" in req["model_id"], "expected HF org/repo id, got %r" % req["model_id"]
        staged = os.path.join(req["model_root"], ".voicey-fetch-staging", req["relative_path"])
        os.makedirs(os.path.dirname(staged), exist_ok=True)
        with open(staged, "wb") as handle:
            handle.write(b"stub-weights")
        print(json.dumps({"type": "downloaded_model_file", "id": rid, "staged_path": staged}), flush=True)
    elif kind == "shutdown":
        print(json.dumps({"type": "ok", "id": rid}), flush=True)
        break
    else:
        print(json.dumps({"type": "error", "id": rid, "message": "unexpected request %s" % kind}), flush=True)
"#;

#[test]
fn download_model_promotes_staged_tree_to_model_directory() {
    let workdir = tempfile::tempdir().expect("tempdir");
    let destination = workdir.path().join("models");
    let worker_path = workdir.path().join("mock-fetch-worker.py");

    std::fs::write(&worker_path, MOCK_FETCH_WORKER).expect("write mock worker");
    let mut perms = std::fs::metadata(&worker_path).expect("metadata").permissions();
    perms.set_mode(0o755);
    std::fs::set_permissions(&worker_path, perms).expect("chmod mock worker");

    let mut child = Command::new(env!("CARGO_BIN_EXE_voicey-supervisor"))
        .env("VOICEY_FETCH_WORKER", &worker_path)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .expect("spawn supervisor");

    let request = serde_json::json!({
        "type": "download_model",
        "id": "test-1",
        "model_id": "qwen3-asr-0.6b-6bit",
        "destination_root": destination.to_str().expect("utf-8 destination"),
    })
    .to_string();

    {
        let stdin = child.stdin.as_mut().expect("supervisor stdin");
        writeln!(stdin, "{request}").expect("write request");
        stdin.flush().expect("flush request");
    }

    let mut reader = BufReader::new(child.stdout.take().expect("supervisor stdout"));
    let mut response_line = String::new();
    reader.read_line(&mut response_line).expect("read response");

    // Close stdin so the supervisor terminates, then reap it.
    drop(child.stdin.take());
    let _ = child.wait();

    let response: serde_json::Value =
        serde_json::from_str(response_line.trim()).expect("parse response");

    assert_eq!(
        response["type"], "download_complete",
        "unexpected response: {response_line}"
    );
    assert_eq!(response["model_id"], "qwen3-asr-0.6b-6bit");

    let model_dir = destination.join("qwen3-asr-0.6b-6bit");
    assert_eq!(
        response["path"].as_str().expect("path string"),
        model_dir.to_str().expect("utf-8 model dir")
    );
    assert!(
        model_dir.join("config.json").is_file(),
        "config.json not promoted"
    );
    assert!(
        model_dir.join("model.safetensors").is_file(),
        "model.safetensors not promoted"
    );

    // No staging containers should be left behind after promotion.
    let leftovers: Vec<_> = std::fs::read_dir(&destination)
        .expect("read destination")
        .filter_map(Result::ok)
        .filter(|entry| {
            entry
                .file_name()
                .to_string_lossy()
                .starts_with(".voicey-fetch-download-")
        })
        .collect();
    assert!(leftovers.is_empty(), "staging container left behind");
}
