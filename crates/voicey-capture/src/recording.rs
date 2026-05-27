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

pub struct LiveRecorder {
    stop_tx: Option<mpsc::Sender<()>>,
    join: Option<thread::JoinHandle<Result<Vec<f32>, String>>>,
}

impl LiveRecorder {
    pub fn new() -> Self {
        Self {
            stop_tx: None,
            join: None,
        }
    }

    pub fn is_recording(&self) -> bool {
        self.stop_tx.is_some()
    }

    pub fn start(&mut self) -> Result<(), String> {
        if self.is_recording() {
            return Err("capture already recording".into());
        }
        reset_live_input_level();
        let (stop_tx, stop_rx) = mpsc::channel();
        let join = thread::spawn(move || record_until_stop(stop_rx));
        self.stop_tx = Some(stop_tx);
        self.join = Some(join);
        Ok(())
    }

    pub fn stop(&mut self) -> Result<Vec<f32>, String> {
        let stop_tx = self
            .stop_tx
            .take()
            .ok_or_else(|| "capture not recording".to_string())?;
        let join = self
            .join
            .take()
            .ok_or_else(|| "capture join handle missing".to_string())?;
        let _ = stop_tx.send(());
        let result = join
            .join()
            .map_err(|_| "capture thread panicked".to_string())??;
        reset_live_input_level();
        Ok(result)
    }
}

fn record_until_stop(stop_rx: mpsc::Receiver<()>) -> Result<Vec<f32>, String> {
    let host = cpal::default_host();
    let device = host
        .default_input_device()
        .ok_or_else(|| "no input device".to_string())?;
    let config = device
        .default_input_config()
        .map_err(|error| error.to_string())?;
    let sample_rate = config.sample_rate().0 as f64;
    let channels = config.channels() as usize;

    let buffer: Arc<Mutex<Vec<f32>>> = Arc::new(Mutex::new(Vec::new()));
    let writer = buffer.clone();
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
                    guard.extend_from_slice(&mono_chunk);
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
    let raw = buffer.lock().expect("lock").clone();
    resample_to_16k(raw, sample_rate)
}

fn resample_to_16k(input: Vec<f32>, input_rate: f64) -> Result<Vec<f32>, String> {
    if input.is_empty() {
        return Ok(input);
    }
    if (input_rate - TARGET_SAMPLE_RATE).abs() < 1.0 {
        return Ok(input);
    }
    let output_len = ((input.len() as f64) * TARGET_SAMPLE_RATE / input_rate).ceil() as usize;
    let mut output = Vec::with_capacity(output_len);
    for index in 0..output_len {
        let src_index = (index as f64 * input_rate / TARGET_SAMPLE_RATE) as usize;
        let sample = input
            .get(src_index.min(input.len().saturating_sub(1)))
            .copied()
            .unwrap_or(0.0);
        output.push(sample);
    }
    Ok(output)
}
