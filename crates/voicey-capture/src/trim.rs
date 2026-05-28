//! Trailing low-energy trim — mirrors Swift `AudioCaptureManager.trimTrailingLowEnergyAudio`.

const TARGET_SAMPLE_RATE: f64 = 16_000.0;
const MAX_TRAILING_TRIM_SECONDS: f64 = 0.5;
const TRAILING_RMS_WINDOW_SECONDS: f64 = 0.02;
const TRAILING_RMS_HOP_SECONDS: f64 = 0.01;
const TRAILING_SILENCE_RMS_THRESHOLD: f32 = 0.01;
const MINIMUM_REMAINING_AUDIO_SECONDS: f64 = 0.3;
const MINIMUM_TRIM_SECONDS: f64 = 0.08;

/// Trim low-energy audio from the end to reduce stop-key noise hallucinations.
pub fn trim_trailing_low_energy(samples: &[f32]) -> Vec<f32> {
    if samples.is_empty() {
        return samples.to_vec();
    }

    let max_trim_samples = (MAX_TRAILING_TRIM_SECONDS * TARGET_SAMPLE_RATE) as usize;
    let window_samples = ((TRAILING_RMS_WINDOW_SECONDS * TARGET_SAMPLE_RATE) as usize).max(1);
    let hop_samples = ((TRAILING_RMS_HOP_SECONDS * TARGET_SAMPLE_RATE) as usize).max(1);
    let min_remaining_samples =
        (MINIMUM_REMAINING_AUDIO_SECONDS * TARGET_SAMPLE_RATE) as usize;
    let min_trim_samples = (MINIMUM_TRIM_SECONDS * TARGET_SAMPLE_RATE) as usize;

    if samples.len() <= window_samples {
        return samples.to_vec();
    }

    let bounded_max_trim = max_trim_samples.min(samples.len() - window_samples);
    if bounded_max_trim < min_trim_samples {
        return samples.to_vec();
    }

    let scan_start = samples.len() - bounded_max_trim;
    let mut scan_index = samples.len() - window_samples;
    let mut keep_end_index = samples.len();

    while scan_index >= scan_start {
        let rms = rms_in_window(samples, scan_index, window_samples);
        if rms > TRAILING_SILENCE_RMS_THRESHOLD {
            keep_end_index = scan_index + window_samples;
            break;
        }
        if scan_index < hop_samples {
            break;
        }
        scan_index -= hop_samples;
    }

    keep_end_index = keep_end_index.max(min_remaining_samples);
    let trimmed_sample_count = samples.len().saturating_sub(keep_end_index);
    if trimmed_sample_count < min_trim_samples {
        return samples.to_vec();
    }

    samples[..keep_end_index].to_vec()
}

fn rms_in_window(samples: &[f32], start: usize, count: usize) -> f32 {
    if start >= samples.len() || count == 0 || start + count > samples.len() {
        return 0.0;
    }
    let slice = &samples[start..start + count];
    let sum_sq: f32 = slice.iter().map(|sample| sample * sample).sum();
    (sum_sq / slice.len() as f32).sqrt()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn silence(n: usize) -> Vec<f32> {
        vec![0.0; n]
    }

    fn tone(n: usize, amplitude: f32) -> Vec<f32> {
        vec![amplitude; n]
    }

    #[test]
    fn empty_and_short_unchanged() {
        assert!(trim_trailing_low_energy(&[]).is_empty());
        let short = vec![0.1, 0.2];
        assert_eq!(trim_trailing_low_energy(&short), short);
    }

    #[test]
    fn trims_trailing_silence() {
        let speech = tone(16_000, 0.2); // 1s
        let tail = silence(4_000); // 0.25s silence
        let mut samples = speech;
        samples.extend(tail);
        let trimmed = trim_trailing_low_energy(&samples);
        assert!(trimmed.len() < samples.len());
        assert!(trimmed.len() >= 16_000 / 2);
    }

    #[test]
    fn preserves_loud_tail() {
        let samples = tone(32_000, 0.2);
        assert_eq!(trim_trailing_low_energy(&samples), samples);
    }
}
