use reqwest::Url;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::fs;
use std::io::{self, Read};
use std::path::{Component, Path, PathBuf};

const HUGGING_FACE_BASE_URL: &str = "https://huggingface.co";
const DEFAULT_REVISION: &str = "main";
const FETCH_USER_AGENT: &str = "voicey-fetch/0.1";
const DOWNLOAD_BUFFER_SIZE_BYTES: usize = 256 * 1024;

/// Single source of truth for the staging subdirectory name, shared with the supervisor.
use voicey_protocol::FETCH_STAGING_DIRECTORY_NAME as STAGING_DIRECTORY_NAME;

#[derive(Debug, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum FetchRequest {
    Ping {
        id: String,
    },
    ListModelFiles {
        id: String,
        model_id: String,
        revision: Option<String>,
        patterns: Vec<String>,
    },
    DownloadModelFile {
        id: String,
        model_id: String,
        revision: Option<String>,
        relative_path: String,
        model_root: String,
        expected_sha256: Option<String>,
    },
    PromoteStaging {
        id: String,
        staging_path: String,
        final_path: String,
        manifest: ManifestFile,
    },
    Shutdown {
        id: String,
    },
}

#[derive(Debug, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum FetchResponse {
    Pong { id: String },
    Ok { id: String },
    ListedModelFiles { id: String, files: Vec<String> },
    DownloadedModelFile { id: String, staged_path: String },
    Error { id: String, message: String },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ManifestFile {
    pub version: u32,
    pub files: Vec<ManifestEntry>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ManifestEntry {
    pub path: String,
    pub sha256: String,
    pub size: u64,
}

pub fn sha256_file(path: &Path) -> io::Result<String> {
    let bytes = fs::read(path)?;
    let digest = Sha256::digest(bytes);
    Ok(hex::encode(digest))
}

pub fn write_manifest(path: &Path, manifest: &ManifestFile) -> io::Result<()> {
    let data = serde_json::to_vec_pretty(manifest)
        .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
    fs::write(path, data)
}

pub fn verify_manifest(root: &Path, manifest: &ManifestFile) -> io::Result<()> {
    for entry in &manifest.files {
        let file_path = root.join(&entry.path);
        if !file_path.is_file() {
            return Err(io::Error::new(
                io::ErrorKind::NotFound,
                format!("missing {}", file_path.display()),
            ));
        }
        let hash = sha256_file(&file_path)?;
        if hash != entry.sha256 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("hash mismatch for {}", entry.path),
            ));
        }
    }
    Ok(())
}

pub fn promote_staging(
    staging: &Path,
    final_path: &Path,
    manifest: &ManifestFile,
) -> io::Result<()> {
    verify_manifest(staging, manifest)?;
    if final_path.exists() {
        fs::remove_dir_all(final_path)?;
    }
    if let Some(parent) = final_path.parent() {
        fs::create_dir_all(parent)?;
    }
    fs::rename(staging, final_path)?;
    Ok(())
}

#[derive(Debug, Deserialize)]
struct HuggingFaceTreeEntry {
    path: String,
    #[serde(rename = "type")]
    kind: String,
}

pub fn list_model_files(
    model_id: &str,
    revision: Option<&str>,
    patterns: &[String],
) -> io::Result<Vec<String>> {
    let url = list_repo_files_url(model_id, revision)?;
    let client = build_client()?;
    let response = client.get(url).send().map_err(io::Error::other)?;
    if !response.status().is_success() {
        return Err(io::Error::other(format!("HTTP {}", response.status())));
    }
    let entries: Vec<HuggingFaceTreeEntry> =
        serde_json::from_reader(response).map_err(io::Error::other)?;
    let file_paths = entries
        .into_iter()
        .filter(|entry| entry.kind == "file")
        .map(|entry| entry.path)
        .collect::<Vec<_>>();
    Ok(filter_matching_paths(file_paths, patterns))
}

pub fn download_model_file(
    model_id: &str,
    revision: Option<&str>,
    relative_path: &str,
    model_root: &str,
    expected_sha256: Option<&str>,
) -> io::Result<PathBuf> {
    let url = resolve_file_url(model_id, revision, relative_path)?;
    let staging_path = staging_path_for(model_root, relative_path)?;
    download_to_staging(&url, &staging_path, expected_sha256)
}

pub fn download_to_staging(
    url: &Url,
    staging_path: &Path,
    expected_sha256: Option<&str>,
) -> io::Result<PathBuf> {
    if let Some(parent) = staging_path.parent() {
        fs::create_dir_all(parent)?;
    }
    let client = build_client()?;
    let mut response = client.get(url.clone()).send().map_err(io::Error::other)?;
    if !response.status().is_success() {
        return Err(io::Error::other(format!("HTTP {}", response.status())));
    }
    let mut file = fs::File::create(staging_path)?;
    let mut hasher = Sha256::new();
    let mut buffer = [0u8; DOWNLOAD_BUFFER_SIZE_BYTES];
    loop {
        let read = response.read(&mut buffer).map_err(io::Error::other)?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
        std::io::Write::write_all(&mut file, &buffer[..read])?;
    }
    if let Some(expected) = expected_sha256 {
        let hash = hex::encode(hasher.finalize());
        if hash != expected {
            fs::remove_file(staging_path)?;
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "sha256 mismatch",
            ));
        }
    }
    Ok(staging_path.to_path_buf())
}

fn build_client() -> io::Result<reqwest::blocking::Client> {
    reqwest::blocking::Client::builder()
        .user_agent(FETCH_USER_AGENT)
        .build()
        .map_err(io::Error::other)
}

fn list_repo_files_url(model_id: &str, revision: Option<&str>) -> io::Result<Url> {
    let validated_model_id = validate_model_id(model_id)?;
    let validated_revision = validate_revision(revision.unwrap_or(DEFAULT_REVISION))?;
    let mut url = Url::parse(HUGGING_FACE_BASE_URL).map_err(io::Error::other)?;
    {
        let mut segments = url
            .path_segments_mut()
            .map_err(|_| io::Error::other("invalid HF base URL"))?;
        segments.extend(["api", "models"]);
        segments.extend(validated_model_id.iter().map(String::as_str));
        segments.extend(["tree", &validated_revision]);
    }
    url.query_pairs_mut().append_pair("recursive", "1");
    Ok(url)
}

fn resolve_file_url(
    model_id: &str,
    revision: Option<&str>,
    relative_path: &str,
) -> io::Result<Url> {
    let validated_model_id = validate_model_id(model_id)?;
    let validated_revision = validate_revision(revision.unwrap_or(DEFAULT_REVISION))?;
    let relative_segments = validate_relative_path(relative_path)?;
    let mut url = Url::parse(HUGGING_FACE_BASE_URL).map_err(io::Error::other)?;
    {
        let mut segments = url
            .path_segments_mut()
            .map_err(|_| io::Error::other("invalid HF base URL"))?;
        segments.extend(validated_model_id.iter().map(String::as_str));
        segments.extend(["resolve", &validated_revision]);
        segments.extend(relative_segments.iter().map(String::as_str));
    }
    Ok(url)
}

fn staging_path_for(model_root: &str, relative_path: &str) -> io::Result<PathBuf> {
    let model_root = validate_model_root(model_root)?;
    let relative_segments = validate_relative_path(relative_path)?;
    let mut path = model_root.join(STAGING_DIRECTORY_NAME);
    for segment in relative_segments {
        path.push(segment);
    }
    Ok(path)
}

fn validate_model_root(model_root: &str) -> io::Result<PathBuf> {
    let path = PathBuf::from(model_root);
    if !path.is_absolute() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "model_root must be an absolute path",
        ));
    }
    Ok(path)
}

fn validate_model_id(model_id: &str) -> io::Result<Vec<String>> {
    let segments = model_id
        .split('/')
        .map(str::trim)
        .filter(|segment| !segment.is_empty())
        .map(str::to_string)
        .collect::<Vec<_>>();
    if segments.len() != 2 || segments.iter().any(|segment| !is_valid_segment(segment)) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("invalid model_id: {model_id}"),
        ));
    }
    Ok(segments)
}

fn validate_revision(revision: &str) -> io::Result<String> {
    let revision = revision.trim();
    if revision.is_empty() || !is_valid_segment(revision) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("invalid revision: {revision}"),
        ));
    }
    Ok(revision.to_string())
}

fn validate_relative_path(relative_path: &str) -> io::Result<Vec<String>> {
    let path = Path::new(relative_path);
    if path.is_absolute() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("absolute paths are not allowed: {relative_path}"),
        ));
    }

    let mut segments = Vec::new();
    for component in path.components() {
        match component {
            Component::Normal(segment) => {
                let segment = segment.to_str().ok_or_else(|| {
                    io::Error::new(io::ErrorKind::InvalidInput, "path must be valid UTF-8")
                })?;
                if !is_valid_segment(segment) {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidInput,
                        format!("invalid path segment: {segment}"),
                    ));
                }
                segments.push(segment.to_string());
            }
            _ => {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    format!("invalid relative path: {relative_path}"),
                ))
            }
        }
    }

    if segments.is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "relative_path must not be empty",
        ));
    }

    Ok(segments)
}

fn filter_matching_paths(file_paths: Vec<String>, patterns: &[String]) -> Vec<String> {
    let mut filtered = file_paths
        .into_iter()
        .filter(|path| patterns.iter().any(|pattern| glob_matches(pattern, path)))
        .collect::<Vec<_>>();
    filtered.sort();
    filtered
}

fn glob_matches(glob: &str, path: &str) -> bool {
    if glob == path {
        return true;
    }
    if glob.starts_with("*.") && path.ends_with(&glob[1..]) {
        return true;
    }
    glob == "*.safetensors" && path.ends_with(".safetensors")
}

fn is_valid_segment(segment: &str) -> bool {
    !segment.is_empty()
        && segment != "."
        && segment != ".."
        && !segment.contains('\\')
        && segment.bytes().all(
            |byte| matches!(byte, b'a'..=b'z' | b'A'..=b'Z' | b'0'..=b'9' | b'-' | b'_' | b'.'),
        )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sha256_file_matches_known_digest() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("sample.bin");
        std::fs::write(&path, b"voicey-fetch").expect("write sample");

        let hash = sha256_file(&path).expect("hash file");

        assert_eq!(
            hash,
            "06dc703676618466b85dad19d81a125eb73cd9edc3f44117c4f0c53734726447"
        );
    }

    #[test]
    fn verify_manifest_rejects_hash_mismatch() {
        let dir = tempfile::tempdir().expect("tempdir");
        let file_path = dir.path().join("weights.bin");
        std::fs::write(&file_path, b"abc").expect("write weights");

        let manifest = ManifestFile {
            version: 1,
            files: vec![ManifestEntry {
                path: "weights.bin".into(),
                sha256: "deadbeef".into(),
                size: 3,
            }],
        };

        let error = verify_manifest(dir.path(), &manifest).expect_err("hash mismatch");
        assert_eq!(error.kind(), io::ErrorKind::InvalidData);
    }

    #[test]
    fn promote_staging_moves_verified_tree() {
        let staging = tempfile::tempdir().expect("staging dir");
        let final_root = tempfile::tempdir().expect("final dir");
        let model_path = staging.path().join("model.bin");
        std::fs::write(&model_path, b"model-bytes").expect("write model");

        let hash = sha256_file(&model_path).expect("hash model");
        let manifest = ManifestFile {
            version: 1,
            files: vec![ManifestEntry {
                path: "model.bin".into(),
                sha256: hash,
                size: 11,
            }],
        };
        write_manifest(&staging.path().join("manifest.json"), &manifest).expect("write manifest");

        let destination = final_root.path().join("qwen3-asr-0.6b-6bit");
        promote_staging(staging.path(), &destination, &manifest).expect("promote staging");

        let promoted = destination.join("model.bin");
        assert!(promoted.is_file());
        assert_eq!(
            std::fs::read(&promoted).expect("read promoted"),
            b"model-bytes"
        );
    }

    #[test]
    fn validate_model_id_rejects_invalid_input() {
        assert!(validate_model_id("aufklarer/Qwen3-ASR-0.6B-MLX-4bit").is_ok());
        assert!(validate_model_id("aufklarer").is_err());
        assert!(validate_model_id("aufklarer/Qwen3/extra").is_err());
        assert!(validate_model_id("../escape/repo").is_err());
    }

    #[test]
    fn validate_relative_path_rejects_traversal() {
        assert!(validate_relative_path("config.json").is_ok());
        assert!(validate_relative_path("tokenizer/config.json").is_ok());
        assert!(validate_relative_path("../config.json").is_err());
        assert!(validate_relative_path("/tmp/config.json").is_err());
        assert!(validate_relative_path("weights\\model.bin").is_err());
    }

    #[test]
    fn staging_path_uses_fixed_subdirectory() {
        let path =
            staging_path_for("/tmp/voicey-model", "tokenizer/config.json").expect("staging path");
        assert_eq!(
            path,
            PathBuf::from("/tmp/voicey-model")
                .join(STAGING_DIRECTORY_NAME)
                .join("tokenizer")
                .join("config.json")
        );
    }

    #[test]
    fn filter_matching_paths_keeps_expected_model_files() {
        let files = vec![
            "config.json".to_string(),
            "README.md".to_string(),
            "model.safetensors".to_string(),
            "nested/weights.safetensors".to_string(),
            "tokenizer.json".to_string(),
        ];
        let filtered = filter_matching_paths(
            files,
            &["config.json".to_string(), "*.safetensors".to_string()],
        );
        assert_eq!(
            filtered,
            vec![
                "config.json".to_string(),
                "model.safetensors".to_string(),
                "nested/weights.safetensors".to_string(),
            ]
        );
    }
}
