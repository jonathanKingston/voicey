//! Golden JSON contract tests — see `fixtures/` and `docs/RUST_PROTOCOL.md`.

use std::fs;
use std::path::{Path, PathBuf};

use serde::de::DeserializeOwned;
use serde::Serialize;

use crate::{
    HostRequest, HostResponse, InferWorkerRequest, InferWorkerResponse, RuntimeKind,
};

fn fixtures_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("fixtures")
}

fn read_json(path: &Path) -> String {
    fs::read_to_string(path).unwrap_or_else(|error| {
        panic!("read fixture {}: {error}", path.display())
    })
}

fn roundtrip_fixture<T>(path: &Path)
where
    T: DeserializeOwned + Serialize + PartialEq + std::fmt::Debug,
{
    let json = read_json(path).trim().to_string();
    let value: T = serde_json::from_str(&json).unwrap_or_else(|error| {
        panic!("deserialize fixture {}: {error}\n{json}", path.display())
    });
    let encoded = serde_json::to_string(&value).unwrap_or_else(|error| {
        panic!("serialize fixture {}: {error}", path.display())
    });
    let roundtrip: T = serde_json::from_str(&encoded).unwrap_or_else(|error| {
        panic!("roundtrip fixture {}: {error}\n{encoded}", path.display())
    });
    assert_eq!(value, roundtrip, "roundtrip mismatch for {}", path.display());
}

fn roundtrip_dir<T>(subdir: &str)
where
    T: DeserializeOwned + Serialize + PartialEq + std::fmt::Debug,
{
    let dir = fixtures_root().join(subdir);
    let mut paths: Vec<_> = fs::read_dir(&dir)
        .unwrap_or_else(|error| panic!("read fixture dir {}: {error}", dir.display()))
        .map(|entry| entry.expect("fixture dir entry").path())
        .filter(|path| path.extension().is_some_and(|ext| ext == "json"))
        .collect();
    paths.sort();
    assert!(!paths.is_empty(), "no fixtures in {}", dir.display());
    for path in paths {
        roundtrip_fixture::<T>(&path);
    }
}

fn reject_fixture<T: DeserializeOwned>(path: &Path) {
    let json = read_json(path);
    let result = serde_json::from_str::<T>(&json);
    let error = match result {
        Ok(_) => panic!("expected deserialize to fail for {}", path.display()),
        Err(error) => error,
    };
    assert!(
        error.to_string().contains("unknown"),
        "expected unknown field/type error for {}, got: {error}",
        path.display()
    );
}

#[test]
fn host_request_fixtures_roundtrip() {
    roundtrip_dir::<HostRequest>("host_request");
}

#[test]
fn host_response_fixtures_roundtrip() {
    roundtrip_dir::<HostResponse>("host_response");
}

#[test]
fn infer_worker_request_fixtures_roundtrip() {
    roundtrip_dir::<InferWorkerRequest>("infer_worker_request");
}

#[test]
fn infer_worker_response_fixtures_roundtrip() {
    roundtrip_dir::<InferWorkerResponse>("infer_worker_response");
}

#[test]
fn runtime_kind_fixtures_roundtrip() {
    roundtrip_dir::<RuntimeKind>("runtime_kind");
}

#[test]
fn host_request_rejects_unknown_field() {
    reject_fixture::<HostRequest>(
        &fixtures_root().join("reject/host_request_ping_extra_field.json"),
    );
}

#[test]
fn host_request_rejects_unknown_type() {
    let path = fixtures_root().join("reject/host_request_unknown_type.json");
    let json = read_json(&path);
    let error = serde_json::from_str::<HostRequest>(&json).unwrap_err();
    assert!(
        error.to_string().contains("unknown variant"),
        "expected unknown variant for {}, got: {error}",
        path.display()
    );
}

#[test]
fn infer_worker_response_rejects_infer_ready_extra_ok_field() {
    reject_fixture::<InferWorkerResponse>(
        &fixtures_root().join("reject/infer_worker_response_infer_ready_extra_ok.json"),
    );
}

#[test]
fn protocol_version_is_documented() {
    assert_eq!(crate::PROTOCOL_VERSION, 1);
}
