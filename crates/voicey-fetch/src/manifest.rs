use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::fs;
use std::io;
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
        .map_err(|e| io::Error::new(io::ErrorKind::Other, e))?;
    let response = client
        .get(url)
        .send()
        .map_err(|e| io::Error::new(io::ErrorKind::Other, e))?;
    if !response.status().is_success() {
        return Err(io::Error::new(
            io::ErrorKind::Other,
            format!("HTTP {}", response.status()),
        ));
    }
    let bytes = response
        .bytes()
        .map_err(|e| io::Error::new(io::ErrorKind::Other, e))?;
    fs::write(staging_path, &bytes)?;
    if let Some(expected) = expected_sha256 {
        let hash = hex::encode(Sha256::digest(&bytes));
        if hash != expected {
            fs::remove_file(staging_path)?;
            return Err(io::Error::new(io::ErrorKind::InvalidData, "sha256 mismatch"));
        }
    }
    Ok(staging_path.to_path_buf())
}
