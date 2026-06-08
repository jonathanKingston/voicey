//! Shared PCM transport between Voicey workers and the Swift host.
//!
//! # Specification (protocol v1)
//!
//! - **Location**: system temp directory (`std::env::temp_dir()` / `FileManager.default.temporaryDirectory`)
//! - **Filename**: `{name}.pcm` where `name` is `voicey_pcm_{id}` and `id` is a UUID v4 hex string (no dashes)
//! - **Format**: little-endian IEEE-754 `f32` samples, mono, typically 16 kHz
//! - **Permissions**: owner read/write only (`0600` on Unix)
//! - **Writer responsibility**: create file atomically where possible with restrictive permissions
//! - **Reader responsibility**: validate byte length >= `sample_count * 4`
//! - **Cleanup**: caller deletes the file when finished; stale `voicey_pcm_*.pcm` files may be removed on app startup/shutdown

use std::fs;
use std::io;
use std::path::{Path, PathBuf};

/// Prefix for PCM shared-memory file names.
pub const NAME_PREFIX: &str = "voicey_pcm_";

/// Owner-only file mode on Unix (`rw-------`).
#[cfg(unix)]
pub const OWNER_ONLY_MODE: u32 = 0o600;

/// Generates a new unique PCM buffer name (`voicey_pcm_{uuid}`).
pub fn new_buffer_name() -> String {
    format!("{NAME_PREFIX}{}", uuid::Uuid::new_v4().simple())
}

pub fn file_path(name: &str) -> PathBuf {
    std::env::temp_dir().join(format!("{name}.pcm"))
}

pub fn write_f32_samples(samples: &[f32]) -> io::Result<String> {
    let name = new_buffer_name();
    let path = file_path(&name);
    let bytes = f32_slice_to_bytes(samples);
    fs::write(&path, bytes)?;
    apply_owner_only_permissions(&path)?;
    Ok(name)
}

pub fn read_f32_samples(name: &str, sample_count: usize) -> io::Result<Vec<f32>> {
    read_f32_samples_slice(name, 0, sample_count)
}

/// Reads `sample_count` mono f32 samples starting at `sample_offset` within the PCM file.
pub fn read_f32_samples_slice(
    name: &str,
    sample_offset: usize,
    sample_count: usize,
) -> io::Result<Vec<f32>> {
    let path = file_path(name);
    let bytes = fs::read(path)?;
    let sample_size = std::mem::size_of::<f32>();
    let byte_offset = sample_offset.saturating_mul(sample_size);
    let expected = sample_count.saturating_mul(sample_size);
    if bytes.len() < byte_offset.saturating_add(expected) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "pcm buffer too small",
        ));
    }
    Ok(bytes_to_f32_slice(
        &bytes[byte_offset..byte_offset + expected],
    ))
}

/// Removes a PCM file. Returns an error when deletion fails (callers may log).
pub fn remove(name: &str) -> io::Result<()> {
    let path = file_path(name);
    match fs::remove_file(&path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error),
    }
}

/// Best-effort removal of stale `voicey_pcm_*.pcm` files in the system temp directory.
pub fn cleanup_stale_files() -> io::Result<usize> {
    cleanup_stale_files_in(&std::env::temp_dir())
}

/// Sweep stale `voicey_pcm_*.pcm` files in a specific directory.
///
/// Factored out so tests can target an isolated directory rather than the shared
/// process temp dir — sweeping the shared temp dir would race sibling tests that
/// create their own PCM files concurrently (cargo runs tests in parallel).
fn cleanup_stale_files_in(dir: &Path) -> io::Result<usize> {
    let entries = match fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(0),
        Err(error) => return Err(error),
    };

    let mut removed = 0usize;
    for entry in entries {
        let entry = entry?;
        let file_name = entry.file_name();
        let file_name = file_name.to_string_lossy();
        if !is_voicey_pcm_file_name(&file_name) {
            continue;
        }
        if remove_file_if_stale(&entry.path()).is_ok() {
            removed += 1;
        }
    }
    Ok(removed)
}

fn is_voicey_pcm_file_name(file_name: &str) -> bool {
    file_name.starts_with(NAME_PREFIX)
        && file_name.ends_with(".pcm")
        && file_name.len() == NAME_PREFIX.len() + 32 + ".pcm".len()
}

fn remove_file_if_stale(path: &Path) -> io::Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        let metadata = fs::metadata(path)?;
        if metadata.uid() != current_uid() {
            return Ok(());
        }
    }
    match fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error),
    }
}

#[cfg(unix)]
fn current_uid() -> u32 {
    // SAFETY: getuid has no failure mode and does not mutate process state relevant to Rust.
    unsafe { libc::getuid() }
}

#[cfg(unix)]
fn apply_owner_only_permissions(path: &Path) -> io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    let mut permissions = fs::metadata(path)?.permissions();
    permissions.set_mode(OWNER_ONLY_MODE);
    fs::set_permissions(path, permissions)
}

#[cfg(not(unix))]
fn apply_owner_only_permissions(_path: &Path) -> io::Result<()> {
    Ok(())
}

fn f32_slice_to_bytes(samples: &[f32]) -> Vec<u8> {
    let mut bytes = Vec::with_capacity(samples.len() * 4);
    for sample in samples {
        bytes.extend_from_slice(&sample.to_le_bytes());
    }
    bytes
}

fn bytes_to_f32_slice(bytes: &[u8]) -> Vec<f32> {
    bytes
        .chunks_exact(4)
        .map(|chunk| f32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip_write_read() {
        let samples = vec![0.0_f32, 0.25, -0.5, 1.0];
        let name = write_f32_samples(&samples).expect("write");
        assert!(name.starts_with(NAME_PREFIX));
        assert_eq!(name.len(), NAME_PREFIX.len() + 32);

        let read_back = read_f32_samples(&name, samples.len()).expect("read");
        assert_eq!(read_back, samples);
        remove(&name).expect("remove");
        assert!(!file_path(&name).exists());
    }

    #[test]
    fn name_uses_uuid_without_dashes() {
        let name = new_buffer_name();
        let id = name.strip_prefix(NAME_PREFIX).expect("prefix");
        assert_eq!(id.len(), 32);
        assert!(id.chars().all(|c| c.is_ascii_hexdigit()));
        assert!(!id.contains('-'));
    }

    #[test]
    fn read_rejects_short_buffer() {
        let name = new_buffer_name();
        let path = file_path(&name);
        fs::write(&path, [0u8; 3]).expect("write short");
        let error = read_f32_samples(&name, 2).expect_err("too small");
        assert_eq!(error.kind(), io::ErrorKind::InvalidData);
        remove(&name).expect("remove");
    }

    #[test]
    fn read_slice_returns_middle_segment() {
        let samples = vec![0.0_f32, 0.25, -0.5, 1.0, 0.75];
        let name = write_f32_samples(&samples).expect("write");
        let slice = read_f32_samples_slice(&name, 1, 3).expect("read slice");
        assert_eq!(slice, vec![0.25, -0.5, 1.0]);
        remove(&name).expect("remove");
    }

    #[cfg(unix)]
    #[test]
    fn write_sets_owner_only_permissions() {
        use std::os::unix::fs::PermissionsExt;

        let name = write_f32_samples(&[1.0_f32]).expect("write");
        let path = file_path(&name);
        let mode = fs::metadata(&path)
            .expect("metadata")
            .permissions()
            .mode()
            & 0o777;
        assert_eq!(mode, OWNER_ONLY_MODE);
        remove(&name).expect("remove");
    }

    #[test]
    fn cleanup_stale_files_removes_matching_pcm() {
        // Use an isolated directory so the sweep cannot race sibling tests that
        // write their own PCM files into the shared temp dir concurrently.
        let dir = std::env::temp_dir().join(new_buffer_name());
        fs::create_dir(&dir).expect("create test dir");

        let path = dir.join(format!("{}.pcm", new_buffer_name()));
        fs::write(&path, [0u8; 4]).expect("write stale");
        #[cfg(unix)]
        apply_owner_only_permissions(&path).expect("chmod");
        // A non-matching file in the same directory must survive the sweep.
        let unrelated = dir.join("voicey_pcm_not_a_uuid.pcm");
        fs::write(&unrelated, [0u8; 4]).expect("write unrelated");

        let removed = cleanup_stale_files_in(&dir).expect("cleanup");
        assert!(removed >= 1);
        assert!(!path.exists());
        assert!(unrelated.exists(), "non-matching file must not be swept");

        fs::remove_dir_all(&dir).ok();
    }
}
