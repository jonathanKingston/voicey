//! Black-box IPC tests for `voicey-text` (spawns the worker binary).

use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};

fn text_bin() -> PathBuf {
    if let Ok(path) = std::env::var("CARGO_BIN_EXE_voicey_text") {
        return PathBuf::from(path);
    }
    let mut path = std::env::current_exe().expect("current_exe");
    path.pop(); // deps
    path.pop(); // debug
    path.join("voicey-text")
}

fn assert_text_bin_exists() {
    let path = text_bin();
    assert!(
        path.exists(),
        "missing voicey-text binary at {} (run cargo test -p voicey-text)",
        path.display()
    );
}

struct TextSession {
    child: Child,
    stdin: std::process::ChildStdin,
    stdout: BufReader<std::process::ChildStdout>,
}

impl TextSession {
    fn spawn() -> Self {
        assert_text_bin_exists();
        let mut child = Command::new(text_bin())
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .expect("spawn voicey-text");
        let stdin = child.stdin.take().expect("text stdin");
        let stdout = child.stdout.take().expect("text stdout");
        Self {
            child,
            stdin,
            stdout: BufReader::new(stdout),
        }
    }

    fn request_json(&mut self, line: &str) -> serde_json::Value {
        writeln!(self.stdin, "{line}").expect("write text stdin");
        self.stdin.flush().expect("flush text stdin");
        let mut response_line = String::new();
        self.stdout
            .read_line(&mut response_line)
            .expect("read text stdout");
        serde_json::from_str(response_line.trim()).unwrap_or_else(|error| {
            panic!(
                "parse text response: {error}\nline={response_line:?}\nrequest={line:?}"
            )
        })
    }
}

impl Drop for TextSession {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

#[test]
fn ping_returns_pong() {
    let mut session = TextSession::spawn();
    let response = session.request_json(r#"{"type":"ping","id":"ping-1"}"#);
    assert_eq!(response["type"], "pong");
    assert_eq!(response["id"], "ping-1");
}

#[test]
fn postprocess_round_trip() {
    let mut session = TextSession::spawn();
    let response = session.request_json(
        r#"{"type":"postprocess","id":"pp-1","text":"hello world","voice_commands_enabled":false}"#,
    );
    assert_eq!(response["type"], "postprocess_result");
    assert_eq!(response["id"], "pp-1");
    assert_eq!(response["ok"], true);
    assert_eq!(response["text"], "hello world");
}

#[test]
fn postprocess_applies_voice_command_new_line() {
    let mut session = TextSession::spawn();
    let response = session.request_json(
        r#"{"type":"postprocess","id":"pp-2","text":"first new line second","voice_commands_enabled":true,"voice_commands":[{"phrase":"new line","action":"new_line","enabled":true}]}"#,
    );
    assert_eq!(response["ok"], true);
    assert_eq!(response["text"], "first \n second");
}

#[test]
fn build_steering_context_manual_glossary() {
    let mut session = TextSession::spawn();
    let response = session.request_json(
        r#"{"type":"build_steering_context","id":"sc-1","manual_glossary_enabled":true,"manual_glossary":"Cursor, Composer","screen_context_enabled":false}"#,
    );
    assert_eq!(response["type"], "steering_context_result");
    assert_eq!(response["id"], "sc-1");
    assert_eq!(response["ok"], true);
    assert_eq!(response["terms"], serde_json::json!(["Cursor", "Composer"]));
    assert!(
        response["decoder_context"]
            .as_str()
            .unwrap_or("")
            .contains("Cursor")
    );
}

#[test]
fn invalid_request_json_returns_error() {
    let mut session = TextSession::spawn();
    let response = session.request_json(r#"{"type":"not_a_text_message","id":"x"}"#);
    assert_eq!(response["type"], "error");
    assert!(
        response["message"]
            .as_str()
            .expect("message")
            .contains("invalid request")
    );
}
