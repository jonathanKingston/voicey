use crate::audio::resample_to_16k;
use hound::{SampleFormat, WavReader, WavSpec};
use std::io;
use std::path::Path;

pub fn load_wav_to_16k_mono_f32(path: &Path) -> io::Result<Vec<f32>> {
    let reader = WavReader::open(path).map_err(|error| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("unable to read wav file: {error}"),
        )
    })?;
    let spec = reader.spec();
    if spec.sample_rate == 0 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "wav file has invalid sample rate",
        ));
    }

    let mono = decode_to_mono_f32(reader, spec)?;
    if mono.is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "wav file contains no readable samples",
        ));
    }

    resample_to_16k(mono, spec.sample_rate as f64)
}

fn decode_to_mono_f32(mut reader: WavReader<std::io::BufReader<std::fs::File>>, spec: WavSpec) -> io::Result<Vec<f32>> {
    let channels = spec.channels.max(1) as usize;
    let mut mono = Vec::new();

    match spec.sample_format {
        SampleFormat::Float => {
            let samples: Vec<f32> = reader
                .samples::<f32>()
                .collect::<Result<_, _>>()
                .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
            if channels == 1 {
                mono = samples;
            } else {
                for frame in samples.chunks(channels) {
                    mono.push(frame.iter().sum::<f32>() / channels as f32);
                }
            }
        }
        SampleFormat::Int => {
            let max_value = (1_i32 << (spec.bits_per_sample.saturating_sub(1))) as f32;
            let samples: Vec<i32> = reader
                .samples::<i32>()
                .collect::<Result<_, _>>()
                .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
            if channels == 1 {
                mono = samples
                    .into_iter()
                    .map(|sample| sample as f32 / max_value)
                    .collect();
            } else {
                for frame in samples.chunks(channels) {
                    let average = frame.iter().sum::<i32>() as f32 / channels as f32;
                    mono.push(average / max_value);
                }
            }
        }
    }

    Ok(mono)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::TARGET_SAMPLE_RATE;
    use hound::{WavSpec, WavWriter};
    use std::io::Cursor;

    fn write_wav(samples: &[f32], sample_rate: u32, channels: u16) -> Vec<u8> {
        let mut buffer = Cursor::new(Vec::new());
        {
            let spec = WavSpec {
                channels,
                sample_rate,
                bits_per_sample: 16,
                sample_format: SampleFormat::Int,
            };
            let mut writer = WavWriter::new(&mut buffer, spec).expect("writer");
            for sample in samples {
                let scaled = (sample.clamp(-1.0, 1.0) * i16::MAX as f32) as i16;
                writer.write_sample(scaled).expect("write");
            }
            writer.finalize().expect("finalize");
        }
        buffer.into_inner()
    }

    #[test]
    fn load_16k_mono_wav_round_trip() {
        let samples = vec![0.0_f32, 0.25, -0.5, 1.0];
        let bytes = write_wav(&samples, TARGET_SAMPLE_RATE as u32, 1);
        let path = std::env::temp_dir().join(format!(
            "voicey_capture_wav_test_{}.wav",
            std::process::id()
        ));
        std::fs::write(&path, bytes).expect("write temp wav");
        let loaded = load_wav_to_16k_mono_f32(&path).expect("load");
        std::fs::remove_file(&path).ok();
        assert_eq!(loaded.len(), samples.len());
        for (actual, expected) in loaded.iter().zip(samples.iter()) {
            assert!((actual - expected).abs() < 0.02, "actual={actual} expected={expected}");
        }
    }

    #[test]
    fn resamples_non_16k_input() {
        let samples = vec![0.0_f32, 1.0, 0.0, -1.0];
        let bytes = write_wav(&samples, 8_000, 1);
        let path = std::env::temp_dir().join(format!(
            "voicey_capture_wav_resample_{}.wav",
            std::process::id()
        ));
        std::fs::write(&path, bytes).expect("write temp wav");
        let loaded = load_wav_to_16k_mono_f32(&path).expect("load");
        std::fs::remove_file(&path).ok();
        assert_eq!(loaded.len(), 8);
    }
}
