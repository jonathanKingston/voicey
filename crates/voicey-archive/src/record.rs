use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

pub const TARGET_SAMPLE_RATE: u32 = 16_000;

/// `index.jsonl` `audio_format` for lossless infer replay (`audio/*.wav`).
pub const AUDIO_FORMAT_WAV_F32: &str = "wav_f32";

pub fn default_audio_format() -> String {
    AUDIO_FORMAT_WAV_F32.to_string()
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum UtteranceArchiveOutcome {
    Completed,
    EmptyDelivery,
    Error,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct UtteranceArchiveScreenSnapshot {
    pub query_text: String,
    pub corpus_chunks: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct UtteranceArchiveRecord {
    pub id: Uuid,
    pub created_at: DateTime<Utc>,
    pub outcome: UtteranceArchiveOutcome,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error_message: Option<String>,
    pub model_id: String,
    pub language_id: String,
    pub audio_seconds: f64,
    pub audio_path: String,
    #[serde(default = "default_audio_format")]
    pub audio_format: String,
    pub raw_text: String,
    pub processed_text: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub partial_transcription: Option<String>,
    pub steering_terms: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub decoder_context_sha256: Option<String>,
    pub glossary_enabled: bool,
    pub screen_context_enabled: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub snapshot_path: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub app_bundle_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub voicey_version: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub runtime: Option<String>,
}

/// Host-provided fields for a new archive entry (paths and id assigned by the store).
#[derive(Debug, Clone, Deserialize)]
pub struct AppendUtteranceMetadata {
    pub outcome: UtteranceArchiveOutcome,
    #[serde(default)]
    pub error_message: Option<String>,
    pub model_id: String,
    pub language_id: String,
    #[serde(default)]
    pub raw_text: String,
    #[serde(default)]
    pub processed_text: String,
    #[serde(default)]
    pub partial_transcription: Option<String>,
    #[serde(default)]
    pub steering_terms: Vec<String>,
    #[serde(default)]
    pub decoder_context_sha256: Option<String>,
    pub glossary_enabled: bool,
    pub screen_context_enabled: bool,
    #[serde(default)]
    pub app_bundle_id: Option<String>,
    #[serde(default)]
    pub voicey_version: Option<String>,
    #[serde(default)]
    pub runtime: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "source", rename_all = "snake_case")]
pub enum ArchiveAudioSource {
    PcmShm {
        shm_name: String,
        sample_count: usize,
        #[serde(default)]
        sample_offset: usize,
    },
    Samples {
        samples: Vec<f32>,
    },
}

impl ArchiveAudioSource {
    pub fn load_samples(&self) -> Result<Vec<f32>, String> {
        match self {
            ArchiveAudioSource::PcmShm {
                shm_name,
                sample_count,
                sample_offset,
            } => voicey_pcm::read_f32_samples_slice(shm_name, *sample_offset, *sample_count)
                .map_err(|error| error.to_string()),
            ArchiveAudioSource::Samples { samples } => Ok(samples.clone()),
        }
    }

    pub fn sample_count(&self) -> usize {
        match self {
            ArchiveAudioSource::PcmShm { sample_count, .. } => *sample_count,
            ArchiveAudioSource::Samples { samples } => samples.len(),
        }
    }
}
