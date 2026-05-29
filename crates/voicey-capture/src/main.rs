mod ipc;
mod recording;
mod trim;

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use recording::{live_input_level, LiveRecorder};
use serde::{Deserialize, Serialize};
use std::io::{BufRead, Write};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

const TARGET_SAMPLE_RATE: f64 = 16_000.0;

static LIVE_RECORDER: OnceLock<Mutex<LiveRecorder>> = OnceLock::new();

fn live_recorder() -> &'static Mutex<LiveRecorder> {
  LIVE_RECORDER.get_or_init(|| Mutex::new(LiveRecorder::new()))
}

#[derive(Debug, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum CaptureRequest {
    Ping { id: String },
    Prewarm { id: String },
    StartRecording { id: String },
    StopRecording {
        id: String,
        #[serde(default = "default_apply_trailing_trim")]
        apply_trailing_trim: bool,
    },
    GetLevel { id: String },
    RecordFixture { id: String, duration_seconds: f64 },
    Shutdown { id: String },
}

#[derive(Debug, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum CaptureResponse {
    Pong { id: String },
    CaptureReady { id: String },
    CaptureFixtureResult {
        id: String,
        ok: bool,
        shm_name: Option<String>,
        sample_count: Option<usize>,
        sample_rate: Option<u32>,
        error: Option<String>,
    },
    CaptureLevel {
        id: String,
        level: f32,
    },
    Error { id: String, message: String },
}

fn main() {
    if let Err(error) = run(std::io::stdin().lock(), std::io::stdout()) {
        eprintln!("voicey-capture fatal: {error}");
        std::process::exit(1);
    }
}

fn run(mut input: impl BufRead, mut output: impl Write) -> std::io::Result<()> {
    let mut line = String::new();
    let mut warmed = false;
    loop {
        line.clear();
        if input.read_line(&mut line)? == 0 {
            break;
        }
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        let response = handle_request(trimmed, &mut warmed);
        let json = serde_json::to_string(&response).map_err(|e| {
            std::io::Error::new(std::io::ErrorKind::InvalidData, e)
        })?;
        writeln!(output, "{json}")?;
        output.flush()?;
    }
    Ok(())
}

fn handle_request(line: &str, warmed: &mut bool) -> CaptureResponse {
    let request: CaptureRequest = match serde_json::from_str(line) {
        Ok(value) => value,
        Err(error) => {
            return CaptureResponse::Error {
                id: String::new(),
                message: format!("invalid request: {error}"),
            };
        }
    };

    match request {
        CaptureRequest::Ping { id } => CaptureResponse::Pong { id },
        CaptureRequest::Prewarm { id } => {
            match prewarm_device() {
                Ok(()) => {
                    *warmed = true;
                    CaptureResponse::CaptureReady { id }
                }
                Err(error) => CaptureResponse::Error {
                    id,
                    message: error.to_string(),
                },
            }
        }
        CaptureRequest::StartRecording { id } => {
            let mut recorder = live_recorder().lock().expect("recorder lock");
            match recorder.start() {
                Ok(()) => CaptureResponse::CaptureReady { id },
                Err(message) => CaptureResponse::Error { id, message },
            }
        }
        CaptureRequest::StopRecording { id, apply_trailing_trim } => {
            match stop_live_recording(apply_trailing_trim) {
                Ok((shm_name, count)) => CaptureResponse::CaptureFixtureResult {
                    id,
                    ok: true,
                    shm_name: Some(shm_name),
                    sample_count: Some(count),
                    sample_rate: Some(TARGET_SAMPLE_RATE as u32),
                    error: None,
                },
                Err(message) => CaptureResponse::CaptureFixtureResult {
                    id,
                    ok: false,
                    shm_name: None,
                    sample_count: None,
                    sample_rate: None,
                    error: Some(message),
                },
            }
        }
        CaptureRequest::GetLevel { id } => CaptureResponse::CaptureLevel {
            id,
            level: live_input_level(),
        },
        CaptureRequest::RecordFixture { id, duration_seconds } => {
            if duration_seconds <= 0.0 || duration_seconds > 30.0 {
                return CaptureResponse::CaptureFixtureResult {
                    id,
                    ok: false,
                    shm_name: None,
                    sample_count: None,
                    sample_rate: None,
                    error: Some("duration out of range".into()),
                };
            }
            match record_silence_fixture(duration_seconds) {
                Ok((shm_name, count)) => CaptureResponse::CaptureFixtureResult {
                    id,
                    ok: true,
                    shm_name: Some(shm_name),
                    sample_count: Some(count),
                    sample_rate: Some(TARGET_SAMPLE_RATE as u32),
                    error: None,
                },
                Err(error) => CaptureResponse::CaptureFixtureResult {
                    id,
                    ok: false,
                    shm_name: None,
                    sample_count: None,
                    sample_rate: None,
                    error: Some(error.to_string()),
                },
            }
        }
        CaptureRequest::Shutdown { id } => CaptureResponse::Pong { id },
    }
}

fn default_apply_trailing_trim() -> bool {
    true
}

fn stop_live_recording(apply_trailing_trim: bool) -> Result<(String, usize), String> {
    let mut recorder = live_recorder().lock().expect("recorder lock");
    let samples = recorder.stop()?;
    let trimmed = trim::maybe_trim_trailing_low_energy(&samples, apply_trailing_trim);
    let shm_name = voicey_pcm::write_f32_samples(&trimmed).map_err(|error| error.to_string())?;
    Ok((shm_name, trimmed.len()))
}

fn prewarm_device() -> std::io::Result<()> {
    let host = cpal::default_host();
    let _device = host
        .default_input_device()
        .ok_or_else(|| std::io::Error::new(std::io::ErrorKind::NotFound, "no input device"))?;
    Ok(())
}

/// Records mono f32 PCM at 16 kHz (synthetic silence when input unavailable in CI).
fn record_silence_fixture(duration_seconds: f64) -> std::io::Result<(String, usize)> {
    let sample_count = (duration_seconds * TARGET_SAMPLE_RATE).round() as usize;
    let mut samples = vec![0.0_f32; sample_count];

    if let Ok(captured) = capture_live_samples(duration_seconds) {
        if captured.len() == sample_count {
            samples = captured;
        } else if !captured.is_empty() {
            samples.truncate(captured.len().min(sample_count));
            samples.resize(sample_count, 0.0);
            for (index, value) in captured.iter().enumerate().take(sample_count) {
                samples[index] = *value;
            }
        }
    }

    let shm_name = voicey_pcm::write_f32_samples(&samples)?;
    Ok((shm_name, samples.len()))
}

fn capture_live_samples(duration_seconds: f64) -> std::io::Result<Vec<f32>> {
    let host = cpal::default_host();
    let device = host
        .default_input_device()
        .ok_or_else(|| std::io::Error::new(std::io::ErrorKind::NotFound, "no input device"))?;
    let config = device
        .default_input_config()
        .map_err(std::io::Error::other)?;
    let sample_rate = config.sample_rate().0 as f64;
    let channels = config.channels() as usize;

    let buffer: Arc<Mutex<Vec<f32>>> = Arc::new(Mutex::new(Vec::new()));
    let writer = buffer.clone();
    let stream = match config.sample_format() {
        cpal::SampleFormat::F32 => device.build_input_stream(
            &config.into(),
            move |data: &[f32], _| {
                let mut guard = writer.lock().expect("lock");
                for frame in data.chunks(channels) {
                    guard.push(frame[0]);
                }
            },
            |error| eprintln!("voicey-capture stream error: {error}"),
            None,
        ),
        _ => {
            return Err(std::io::Error::new(
                std::io::ErrorKind::Unsupported,
                "unsupported sample format",
            ))
        }
    }
    .map_err(std::io::Error::other)?;

    stream.play().map_err(std::io::Error::other)?;
    std::thread::sleep(Duration::from_secs_f64(duration_seconds));
    drop(stream);

    let raw = buffer.lock().expect("lock").clone();
    resample_to_16k(raw, sample_rate)
}

fn resample_to_16k(input: Vec<f32>, input_rate: f64) -> std::io::Result<Vec<f32>> {
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
        let sample = input.get(src_index.min(input.len() - 1)).copied().unwrap_or(0.0);
        output.push(sample);
    }
    Ok(output)
}
