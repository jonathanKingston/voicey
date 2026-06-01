//! Regenerate golden JSON under `fixtures/`. Run from crate root:
//! `cargo run -p voicey-protocol --bin gen-fixtures`

use std::fs;
use std::path::PathBuf;
use voicey_protocol::{
    HostRequest, HostResponse, InferWorkerRequest, InferWorkerResponse, RuntimeKind,
};

fn main() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("fixtures");
    write_fixture(&root.join("host_request/ping.json"), &HostRequest::Ping {
        id: "fixture-ping-001".into(),
    });
    write_fixture(
        &root.join("host_request/prewarm_all_workers.json"),
        &HostRequest::PrewarmAllWorkers {
            id: "fixture-prewarm-all-001".into(),
            model_id: "qwen3-asr-0.6b-6bit".into(),
        },
    );
    write_fixture(
        &root.join("host_request/prewarm_infer.json"),
        &HostRequest::PrewarmInfer {
            id: "fixture-prewarm-infer-001".into(),
            model_id: "qwen3-asr-0.6b-6bit".into(),
        },
    );
    write_fixture(
        &root.join("host_request/prewarm_capture.json"),
        &HostRequest::PrewarmCapture {
            id: "fixture-prewarm-capture-001".into(),
        },
    );
    write_fixture(
        &root.join("host_request/load_model.json"),
        &HostRequest::LoadModel {
            id: "fixture-load-model-001".into(),
            model_id: "qwen3-asr-0.6b-6bit".into(),
        },
    );
    write_fixture(
        &root.join("host_request/unload_model.json"),
        &HostRequest::UnloadModel {
            id: "fixture-unload-model-001".into(),
        },
    );
    write_fixture(
        &root.join("host_request/transcribe.json"),
        &HostRequest::Transcribe {
            id: "fixture-transcribe-001".into(),
            model_id: "qwen3-asr-0.6b-6bit".into(),
            sample_rate: 16_000,
            shm_name: "voicey-pcm-fixture".into(),
            sample_count: 1024,
            sample_offset: 0,
            decoder_context: Some("Glossary: Voicey".into()),
            language: Some("English".into()),
        },
    );
    write_fixture(
        &root.join("host_request/transcribe_minimal.json"),
        &HostRequest::Transcribe {
            id: "fixture-transcribe-002".into(),
            model_id: "qwen3-asr-0.6b-6bit".into(),
            sample_rate: 16_000,
            shm_name: "voicey-pcm-fixture".into(),
            sample_count: 512,
            sample_offset: 0,
            decoder_context: None,
            language: None,
        },
    );
    write_fixture(
        &root.join("host_request/transcribe_slice.json"),
        &HostRequest::Transcribe {
            id: "fixture-transcribe-003".into(),
            model_id: "qwen3-asr-0.6b-6bit".into(),
            sample_rate: 16_000,
            shm_name: "voicey-pcm-fixture".into(),
            sample_count: 256,
            sample_offset: 128,
            decoder_context: None,
            language: None,
        },
    );
    write_fixture(
        &root.join("host_request/download_model.json"),
        &HostRequest::DownloadModel {
            id: "fixture-download-001".into(),
            model_id: "qwen3-asr-0.6b-6bit".into(),
            destination_root: "Models/Qwen".into(),
        },
    );
    write_fixture(
        &root.join("host_request/cancel_download.json"),
        &HostRequest::CancelDownload {
            id: "fixture-cancel-download-001".into(),
            model_id: "qwen3-asr-0.6b-6bit".into(),
        },
    );
    write_fixture(
        &root.join("host_request/start_capture.json"),
        &HostRequest::StartCapture {
            id: "fixture-start-capture-001".into(),
        },
    );
    write_fixture(
        &root.join("host_request/stop_capture.json"),
        &HostRequest::StopCapture {
            id: "fixture-stop-capture-001".into(),
        },
    );
    write_fixture(
        &root.join("host_request/capture_fixture.json"),
        &HostRequest::CaptureFixture {
            id: "fixture-capture-fixture-001".into(),
            duration_seconds: 1.5,
        },
    );

    write_fixture(&root.join("host_response/pong.json"), &HostResponse::Pong {
        id: "fixture-pong-001".into(),
    });
    write_fixture(&root.join("host_response/ready.json"), &HostResponse::Ready {
        id: "fixture-ready-001".into(),
    });
    write_fixture(
        &root.join("host_response/infer_ready.json"),
        &HostResponse::InferReady {
            id: "fixture-infer-ready-001".into(),
            model_id: "qwen3-asr-0.6b-6bit".into(),
        },
    );
    write_fixture(
        &root.join("host_response/capture_ready.json"),
        &HostResponse::CaptureReady {
            id: "fixture-capture-ready-001".into(),
        },
    );
    write_fixture(
        &root.join("host_response/transcribe_result_ok.json"),
        &HostResponse::TranscribeResult {
            id: "fixture-transcribe-result-001".into(),
            ok: true,
            raw_text: Some("hello world".into()),
            language: Some("en".into()),
            processing_seconds: Some(0.42),
            audio_seconds: Some(1.0),
            error: None,
        },
    );
    write_fixture(
        &root.join("host_response/transcribe_result_error.json"),
        &HostResponse::TranscribeResult {
            id: "fixture-transcribe-result-002".into(),
            ok: false,
            raw_text: None,
            language: None,
            processing_seconds: None,
            audio_seconds: None,
            error: Some("model not loaded".into()),
        },
    );
    write_fixture(
        &root.join("host_response/download_progress.json"),
        &HostResponse::DownloadProgress {
            id: "fixture-download-progress-001".into(),
            model_id: "qwen3-asr-0.6b-6bit".into(),
            progress: 0.5,
        },
    );
    write_fixture(
        &root.join("host_response/download_complete.json"),
        &HostResponse::DownloadComplete {
            id: "fixture-download-complete-001".into(),
            model_id: "qwen3-asr-0.6b-6bit".into(),
            path: "/tmp/voicey-models/qwen3-asr-0.6b-6bit".into(),
        },
    );
    write_fixture(
        &root.join("host_response/download_failed.json"),
        &HostResponse::DownloadFailed {
            id: "fixture-download-failed-001".into(),
            model_id: "qwen3-asr-0.6b-6bit".into(),
            error: "network error".into(),
        },
    );
    write_fixture(
        &root.join("host_response/capture_stopped.json"),
        &HostResponse::CaptureStopped {
            id: "fixture-capture-stopped-001".into(),
            shm_name: "voicey-pcm-fixture".into(),
            sample_count: 16_000,
            sample_rate: 16_000,
        },
    );
    write_fixture(
        &root.join("host_response/capture_fixture_result_ok.json"),
        &HostResponse::CaptureFixtureResult {
            id: "fixture-capture-fixture-result-001".into(),
            ok: true,
            shm_name: Some("voicey-pcm-fixture".into()),
            sample_count: Some(24_000),
            error: None,
        },
    );
    write_fixture(
        &root.join("host_response/capture_fixture_result_error.json"),
        &HostResponse::CaptureFixtureResult {
            id: "fixture-capture-fixture-result-002".into(),
            ok: false,
            shm_name: None,
            sample_count: None,
            error: Some("capture timeout".into()),
        },
    );
    write_fixture(&root.join("host_response/error.json"), &HostResponse::Error {
        id: "fixture-error-001".into(),
        message: "invalid request".into(),
    });

    write_fixture(
        &root.join("infer_worker_request/ping.json"),
        &InferWorkerRequest::Ping {
            id: "fixture-infer-ping-001".into(),
        },
    );
    write_fixture(
        &root.join("infer_worker_request/load_model.json"),
        &InferWorkerRequest::LoadModel {
            id: "fixture-infer-load-001".into(),
            model_id: "qwen3-asr-0.6b-6bit".into(),
        },
    );
    write_fixture(
        &root.join("infer_worker_request/unload_model.json"),
        &InferWorkerRequest::UnloadModel {
            id: "fixture-infer-unload-001".into(),
        },
    );
    write_fixture(
        &root.join("infer_worker_request/transcribe.json"),
        &InferWorkerRequest::Transcribe {
            id: "fixture-infer-transcribe-001".into(),
            model_id: "qwen3-asr-0.6b-6bit".into(),
            sample_rate: 16_000,
            shm_name: "voicey-pcm-fixture".into(),
            sample_count: 1024,
            sample_offset: 0,
            decoder_context: Some("Glossary: Voicey".into()),
            language: Some("English".into()),
        },
    );
    write_fixture(
        &root.join("infer_worker_request/transcribe_minimal.json"),
        &InferWorkerRequest::Transcribe {
            id: "fixture-infer-transcribe-002".into(),
            model_id: "qwen3-asr-0.6b-6bit".into(),
            sample_rate: 16_000,
            shm_name: "voicey-pcm-fixture".into(),
            sample_count: 512,
            sample_offset: 0,
            decoder_context: None,
            language: None,
        },
    );
    write_fixture(
        &root.join("infer_worker_request/transcribe_slice.json"),
        &InferWorkerRequest::Transcribe {
            id: "fixture-infer-transcribe-003".into(),
            model_id: "qwen3-asr-0.6b-6bit".into(),
            sample_rate: 16_000,
            shm_name: "voicey-pcm-fixture".into(),
            sample_count: 256,
            sample_offset: 128,
            decoder_context: None,
            language: None,
        },
    );
    write_fixture(
        &root.join("infer_worker_request/shutdown.json"),
        &InferWorkerRequest::Shutdown {
            id: "fixture-infer-shutdown-001".into(),
        },
    );

    write_fixture(
        &root.join("infer_worker_response/pong.json"),
        &InferWorkerResponse::Pong {
            id: "fixture-infer-pong-resp-001".into(),
        },
    );
    write_fixture(
        &root.join("infer_worker_response/ready.json"),
        &InferWorkerResponse::Ready {
            id: "fixture-infer-ready-resp-001".into(),
        },
    );
    write_fixture(
        &root.join("infer_worker_response/infer_ready.json"),
        &InferWorkerResponse::InferReady {
            id: "fixture-infer-ready-resp-002".into(),
            model_id: "qwen3-asr-0.6b-6bit".into(),
        },
    );
    write_fixture(
        &root.join("infer_worker_response/transcribe_result_ok.json"),
        &InferWorkerResponse::TranscribeResult {
            id: "fixture-infer-transcribe-resp-001".into(),
            ok: true,
            raw_text: Some("hello world".into()),
            language: Some("en".into()),
            processing_seconds: Some(0.42),
            audio_seconds: Some(1.0),
            error: None,
        },
    );
    write_fixture(
        &root.join("infer_worker_response/transcribe_result_error.json"),
        &InferWorkerResponse::TranscribeResult {
            id: "fixture-infer-transcribe-resp-002".into(),
            ok: false,
            raw_text: None,
            language: None,
            processing_seconds: None,
            audio_seconds: None,
            error: Some("model not loaded".into()),
        },
    );
    write_fixture(
        &root.join("infer_worker_response/error.json"),
        &InferWorkerResponse::Error {
            id: "fixture-infer-error-001".into(),
            message: "invalid request".into(),
        },
    );

    write_fixture(
        &root.join("runtime_kind/in_process.json"),
        &RuntimeKind::InProcess,
    );
    write_fixture(
        &root.join("runtime_kind/multiprocess.json"),
        &RuntimeKind::Multiprocess,
    );

    fs::create_dir_all(root.join("reject")).expect("create reject dir");
    fs::write(
        root.join("reject/host_request_ping_extra_field.json"),
        r#"{"type":"ping","id":"fixture-ping-001","unexpected_field":true}"#,
    )
    .expect("write reject fixture");
    fs::write(
        root.join("reject/host_request_unknown_type.json"),
        r#"{"type":"not_a_real_message","id":"fixture-unknown-001"}"#,
    )
    .expect("write unknown type fixture");
    // Legacy infer-worker emitted `ok` on infer_ready; supervisor must reject (deny_unknown_fields).
    fs::write(
        root.join("reject/infer_worker_response_infer_ready_extra_ok.json"),
        r#"{"type":"infer_ready","id":"fixture-infer-ready-legacy","model_id":"qwen3-asr-0.6b-6bit","ok":true}"#,
    )
    .expect("write infer_ready extra ok reject fixture");

    eprintln!("wrote fixtures under {}", root.display());
}

fn write_fixture<T: serde::Serialize>(path: &std::path::Path, value: &T) {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).expect("create fixture dir");
    }
    let json = serde_json::to_string_pretty(value).expect("serialize fixture");
    fs::write(path, format!("{json}\n")).expect("write fixture");
}
