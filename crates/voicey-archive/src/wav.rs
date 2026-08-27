use crate::record::TARGET_SAMPLE_RATE;
use hound::{SampleFormat, WavSpec, WavWriter};
use std::io;
use std::path::Path;

/// Lossless mono f32 @ 16 kHz (IEEE float samples, same values as infer input).
pub fn write_mono_16k_f32(samples: &[f32], path: &Path) -> io::Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let spec = WavSpec {
        channels: 1,
        sample_rate: TARGET_SAMPLE_RATE,
        bits_per_sample: 32,
        sample_format: SampleFormat::Float,
    };
    let mut writer = WavWriter::create(path, spec).map_err(hound_error)?;
    for sample in samples {
        writer.write_sample(*sample).map_err(hound_error)?;
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
    use hound::{SampleFormat, WavReader};
    use tempfile::tempdir;

    #[test]
    fn writes_16k_mono_f32_wav() {
        let dir = tempdir().expect("tempdir");
        let path = dir.path().join("test.wav");
        let samples = [0.0_f32, 0.5, -0.5, f32::from_bits(0x3f800000)];
        write_mono_16k_f32(&samples, &path).expect("write");
        let mut reader = WavReader::open(&path).expect("open");
        assert_eq!(reader.spec().sample_rate, TARGET_SAMPLE_RATE);
        assert_eq!(reader.spec().channels, 1);
        assert_eq!(reader.spec().bits_per_sample, 32);
        assert_eq!(reader.spec().sample_format, SampleFormat::Float);
        let read_back: Vec<f32> = reader
            .samples::<f32>()
            .collect::<Result<_, _>>()
            .expect("samples");
        assert_eq!(read_back, samples);
    }
}
