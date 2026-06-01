use crate::record::TARGET_SAMPLE_RATE;
use hound::{SampleFormat, WavSpec, WavWriter};
use std::io;
use std::path::Path;

pub fn write_mono_16k_pcm16(samples: &[f32], path: &Path) -> io::Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let spec = WavSpec {
        channels: 1,
        sample_rate: TARGET_SAMPLE_RATE,
        bits_per_sample: 16,
        sample_format: SampleFormat::Int,
    };
    let mut writer = WavWriter::create(path, spec).map_err(hound_error)?;
    for sample in samples {
        let clamped = sample.clamp(-1.0, 1.0);
        let scaled = (clamped * i16::MAX as f32).round() as i32;
        writer
            .write_sample(scaled.clamp(i16::MIN as i32, i16::MAX as i32) as i16)
            .map_err(hound_error)?;
    }
    writer.finalize().map_err(hound_error)?;
    Ok(())
}

fn hound_error(error: hound::Error) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, error.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use hound::WavReader;
    use tempfile::tempdir;

    #[test]
    fn writes_16k_mono_pcm16() {
        let dir = tempdir().expect("tempdir");
        let path = dir.path().join("test.wav");
        write_mono_16k_pcm16(&[0.0, 0.5, -0.5], &path).expect("write");
        let reader = WavReader::open(&path).expect("open");
        assert_eq!(reader.spec().sample_rate, TARGET_SAMPLE_RATE);
        assert_eq!(reader.spec().channels, 1);
        assert_eq!(reader.spec().bits_per_sample, 16);
    }
}
