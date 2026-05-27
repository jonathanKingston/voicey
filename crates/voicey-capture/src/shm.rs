use std::fs;
use std::path::PathBuf;

pub fn write_f32_samples(samples: &[f32]) -> std::io::Result<String> {
    let name = format!("voicey_pcm_{}", uuid_simple());
    let path = shm_path(&name);
    let bytes = f32_slice_to_bytes(samples);
    fs::write(&path, bytes)?;
    Ok(name)
}

pub fn read_f32_samples(name: &str, sample_count: usize) -> std::io::Result<Vec<f32>> {
    let path = shm_path(name);
    let bytes = fs::read(path)?;
    let expected = sample_count * std::mem::size_of::<f32>();
    if bytes.len() < expected {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "shm too small",
        ));
    }
    Ok(bytes_to_f32_slice(&bytes[..expected]))
}

fn shm_path(name: &str) -> PathBuf {
    std::env::temp_dir().join(format!("{name}.pcm"))
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

fn uuid_simple() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    format!("{nanos}")
}

pub fn remove_shm(name: &str) {
    let path = shm_path(name);
    let _ = fs::remove_file(path);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn write_read_and_remove_roundtrip() {
        let samples = vec![0.25_f32, -0.5, 1.0];
        let name = write_f32_samples(&samples).expect("write samples");
        let read = read_f32_samples(&name, samples.len()).expect("read samples");
        assert_eq!(read, samples);
        remove_shm(&name);
        assert!(!shm_path(&name).exists());
    }
}
