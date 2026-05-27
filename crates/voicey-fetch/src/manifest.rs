use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::fs;
use std::io::{self, Read};
use std::path::{Path, PathBuf};

#[derive(Debug, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum FetchRequest {
    Ping { id: String },
    DownloadHfFile {
        id: String,
        url: String,
        staging_path: String,
        expected_sha256: Option<String>,
    },
    PromoteStaging {
        id: String,
        staging_path: String,
        final_path: String,
        manifest: ManifestFile,
    },
    Shutdown { id: String },
}

#[derive(Debug, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum FetchResponse {
    Pong { id: String },
    Ok { id: String },
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
    let data = serde_json::to_vec_pretty(manifest).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
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

pub fn promote_staging(staging: &Path, final_path: &Path, manifest: &ManifestFile) -> io::Result<()> {
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

pub fn download_to_staging(url: &str, staging_path: &Path, expected_sha256: Option<&str>) -> io::Result<PathBuf> {
    if let Some(parent) = staging_path.parent() {
        fs::create_dir_all(parent)?;
    }
    let client = reqwest::blocking::Client::builder()
        .user_agent("voicey-fetch/0.1")
        .build()
        .map_err(io::Error::other)?;
    let mut response = client
        .get(url)
        .send()
        .map_err(io::Error::other)?;
    if !response.status().is_success() {
        return Err(io::Error::other(format!("HTTP {}", response.status())));
    }
    let mut file = fs::File::create(staging_path)?;
    let mut hasher = Sha256::new();
    let mut buffer = [0u8; 256 * 1024];
    loop {
        let read = response
            .read(&mut buffer)
            .map_err(io::Error::other)?;
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
            return Err(io::Error::new(io::ErrorKind::InvalidData, "sha256 mismatch"));
        }
    }
    Ok(staging_path.to_path_buf())
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
        assert_eq!(std::fs::read(&promoted).expect("read promoted"), b"model-bytes");
    }
}
