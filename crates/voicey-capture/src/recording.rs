use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

const TARGET_SAMPLE_RATE: f64 = 16_000.0;
/// Safety rail for forgotten recordings (~19 MiB at 16 kHz). Keep aligned with Swift
/// `RecordingDurationLimits.maxSeconds`.
const MAX_RECORDING_SECONDS: f64 = 600.0;

static LIVE_LEVEL_BITS: AtomicU32 = AtomicU32::new(0);

/// Normalized input level 0–1 (matches Swift `calculateRMSLevel` mapping).
pub fn live_input_level() -> f32 {
    f32::from_bits(LIVE_LEVEL_BITS.load(Ordering::Relaxed))
}

pub fn reset_live_input_level() {
    LIVE_LEVEL_BITS.store(0.0f32.to_bits(), Ordering::Relaxed);
}

fn update_live_input_level(samples: &[f32]) {
    if samples.is_empty() {
        return;
    }
    let sum_sq: f32 = samples.iter().map(|sample| sample * sample).sum();
    let rms = (sum_sq / samples.len() as f32).sqrt();
    let decibels = 20.0 * rms.max(1e-5).log10();
    let normalized = ((decibels + 60.0) / 60.0).clamp(0.0, 1.0);
    LIVE_LEVEL_BITS.store(normalized.to_bits(), Ordering::Relaxed);
}

struct LiveRecordingHandle {
    samples: Arc<Mutex<Vec<f32>>>,
    stop_tx: mpsc::Sender<()>,
    join: thread::JoinHandle<Result<(), String>>,
}

pub struct LiveRecorder {
    handle: Option<LiveRecordingHandle>,
}

impl LiveRecorder {
    pub fn new() -> Self {
        Self { handle: None }
    }

    pub fn is_recording(&self) -> bool {
        self.handle.is_some()
    }

    pub fn sample_count(&self) -> usize {
        self.handle
            .as_ref()
            .map(|handle| handle.samples.lock().expect("lock").len())
            .unwrap_or(0)
    }

    pub fn start(&mut self) -> Result<(), String> {
        if self.is_recording() {
            return Err("capture already recording".into());
        }
        reset_live_input_level();
        let samples = Arc::new(Mutex::new(Vec::new()));
        let writer = samples.clone();
        let (stop_tx, stop_rx) = mpsc::channel();
        let join = thread::spawn(move || record_until_stop(writer, stop_rx));
        self.handle = Some(LiveRecordingHandle {
            samples,
            stop_tx,
            join,
        });
        Ok(())
    }

    pub fn drain_utterance(
        &self,
        start_sample_index: usize,
        end_sample_index: usize,
        apply_trailing_trim: bool,
    ) -> Result<Vec<f32>, String> {
        let handle = self
            .handle
            .as_ref()
            .ok_or_else(|| "capture not recording".to_string())?;
        let mut guard = handle.samples.lock().expect("lock");
        let start = start_sample_index.min(guard.len());
        let end = end_sample_index.max(start).min(guard.len());
        let utterance: Vec<f32> = guard[start..end].to_vec();
        guard.drain(..end);
        drop(guard);
        Ok(crate::trim::maybe_trim_trailing_low_energy(
            &utterance,
            apply_trailing_trim,
        ))
    }

    pub fn stop(&mut self) -> Result<Vec<f32>, String> {
        let handle = self
            .handle
            .take()
            .ok_or_else(|| "capture not recording".to_string())?;
        let _ = handle.stop_tx.send(());
        let result = handle
            .join
            .join()
            .map_err(|_| "capture thread panicked".to_string())?;
        result?;
        reset_live_input_level();
        let mut guard = handle.samples.lock().expect("lock");
        Ok(guard.drain(..).collect())
    }
}

fn record_until_stop(
    samples: Arc<Mutex<Vec<f32>>>,
    stop_rx: mpsc::Receiver<()>,
) -> Result<(), String> {
    let host = cpal::default_host();
    let device = host
        .default_input_device()
        .ok_or_else(|| "no input device".to_string())?;
    let config = device
        .default_input_config()
        .map_err(|error| error.to_string())?;
    let sample_rate = config.sample_rate().0 as f64;
    let channels = config.channels() as usize;

    let writer = samples.clone();
    let stream = match config.sample_format() {
        cpal::SampleFormat::F32 => device
            .build_input_stream(
                &config.into(),
                move |data: &[f32], _| {
                    let mut mono_chunk = Vec::with_capacity(data.len() / channels + 1);
                    for frame in data.chunks(channels) {
                        mono_chunk.push(frame[0]);
                    }
                    update_live_input_level(&mono_chunk);
                    let mut guard = writer.lock().expect("lock");
                    append_resampled_chunk(&mut guard, &mono_chunk, sample_rate);
                },
                |error| eprintln!("voicey-capture stream error: {error}"),
                None,
            )
            .map_err(|error| error.to_string())?,
        _ => return Err("unsupported sample format".into()),
    };

    stream.play().map_err(|error| error.to_string())?;

    let started = std::time::Instant::now();
    loop {
        if stop_rx.try_recv().is_ok() {
            break;
        }
        if started.elapsed().as_secs_f64() >= MAX_RECORDING_SECONDS {
            break;
        }
        thread::sleep(Duration::from_millis(20));
    }

    drop(stream);
    Ok(())
}

fn append_resampled_chunk(target: &mut Vec<f32>, chunk: &[f32], input_rate: f64) {
    if chunk.is_empty() {
        return;
    }
    if (input_rate - TARGET_SAMPLE_RATE).abs() < 1.0 {
        target.extend_from_slice(chunk);
        return;
    }
    let output_len = ((chunk.len() as f64) * TARGET_SAMPLE_RATE / input_rate).ceil() as usize;
    target.reserve(output_len);
    for index in 0..output_len {
        let src_index = (index as f64 * input_rate / TARGET_SAMPLE_RATE) as usize;
        let sample = chunk
            .get(src_index.min(chunk.len().saturating_sub(1)))
            .copied()
            .unwrap_or(0.0);
        target.push(sample);
    }
}

#[cfg(test)]
impl LiveRecorder {
    /// Seeds an in-memory buffer without opening CoreAudio/ALSA (unit tests only).
    fn start_with_buffered_samples_for_test(&mut self, samples: Vec<f32>) {
        let buffer = Arc::new(Mutex::new(samples));
        let (stop_tx, stop_rx) = mpsc::channel();
        let join = thread::spawn(move || {
            let _ = stop_rx.recv();
            Ok(())
        });
        self.handle = Some(LiveRecordingHandle {
            samples: buffer,
            stop_tx,
            join,
        });
    }
}

#[cfg(test)]
mod tests {
    use super::LiveRecorder;

    #[test]
    fn drain_utterance_extracts_slice_and_removes_prefix_from_buffer() {
        let mut recorder = LiveRecorder::new();
        recorder.start_with_buffered_samples_for_test((0..10).map(|index| index as f32).collect());
        let drained = recorder
            .drain_utterance(2, 6, false)
            .expect("drain utterance");
        assert_eq!(drained, vec![2.0, 3.0, 4.0, 5.0]);
        assert_eq!(recorder.sample_count(), 4);
        let remainder = recorder.stop().expect("stop");
        assert_eq!(remainder, vec![6.0, 7.0, 8.0, 9.0]);
    }

    #[test]
    fn drain_utterance_clamps_out_of_range_indices() {
        let mut recorder = LiveRecorder::new();
        recorder.start_with_buffered_samples_for_test(vec![1.0, 2.0, 3.0]);
        let drained = recorder
            .drain_utterance(10, 20, false)
            .expect("drain utterance");
        assert!(drained.is_empty());
        // start clamps to len; drain(..end) still removes the buffered prefix.
        assert_eq!(recorder.sample_count(), 0);
    }

    #[test]
    fn drain_utterance_requires_active_recording() {
        let recorder = LiveRecorder::new();
        let error = recorder
            .drain_utterance(0, 1, false)
            .expect_err("expected not recording");
        assert!(error.contains("not recording"));
    }
}
