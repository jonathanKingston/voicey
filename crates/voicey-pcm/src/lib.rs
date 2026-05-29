//! Shared PCM transport between Voicey workers and the Swift host.
//!
//! # Specification (protocol v1)
//!
//! - **Location**: system temp directory (`std::env::temp_dir()` / `FileManager.default.temporaryDirectory`)
//! - **Filename**: `{name}.pcm` where `name` is `voicey_pcm_{id}` and `id` is a UUID v4 hex string (no dashes)
//! - **Format**: little-endian IEEE-754 `f32` samples, mono, typically 16 kHz
//! - **Writer responsibility**: create file atomically where possible
//! - **Reader responsibility**: validate byte length >= `sample_count * 4`
//! - **Cleanup**: caller that finished with the buffer deletes the file (`remove`)

use std::fs;
use std::io;
use std::path::PathBuf;

/// Prefix for PCM shared-memory file names.
pub const NAME_PREFIX: &str = "voicey_pcm_";

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

pub fn remove(name: &str) {
    let path = file_path(name);
    let _ = fs::remove_file(path);
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
        remove(&name);
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
        remove(&name);
    }

    #[test]
    fn read_slice_returns_middle_segment() {
        let samples = vec![0.0_f32, 0.25, -0.5, 1.0, 0.75];
        let name = write_f32_samples(&samples).expect("write");
        let slice = read_f32_samples_slice(&name, 1, 3).expect("read slice");
        assert_eq!(slice, vec![0.25, -0.5, 1.0]);
        remove(&name);
    }
}
