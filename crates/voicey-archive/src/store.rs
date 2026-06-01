use crate::record::{
    AppendUtteranceMetadata, ArchiveAudioSource, UtteranceArchiveRecord,
    UtteranceArchiveScreenSnapshot, TARGET_SAMPLE_RATE,
};
use crate::retention::record_ids_to_evict;
use crate::wav::write_mono_16k_pcm16;
use chrono::Utc;
use std::fs::{self, File, OpenOptions};
use std::io::{self, BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use uuid::Uuid;

pub const INDEX_FILE_NAME: &str = "index.jsonl";

pub struct SessionArchiveStore {
    root: PathBuf,
}

impl SessionArchiveStore {
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Self { root: root.into() }
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    pub fn ensure_layout(&self) -> io::Result<()> {
        fs::create_dir_all(self.root.join("audio"))?;
        fs::create_dir_all(self.root.join("snapshots"))?;
        Ok(())
    }

    pub fn read_index(&self) -> io::Result<Vec<UtteranceArchiveRecord>> {
        let path = self.index_path();
        if !path.is_file() {
            return Ok(Vec::new());
        }
        let file = File::open(path)?;
        let reader = BufReader::new(file);
        let mut records = Vec::new();
        for line in reader.lines() {
            let line = line?;
            let trimmed = line.trim();
            if trimmed.is_empty() {
                continue;
            }
            let record: UtteranceArchiveRecord = serde_json::from_str(trimmed).map_err(|error| {
                io::Error::new(io::ErrorKind::InvalidData, error)
            })?;
            records.push(record);
        }
        Ok(records)
    }

    pub fn append_utterance(
        &self,
        audio: &ArchiveAudioSource,
        metadata: &AppendUtteranceMetadata,
        snapshot: Option<&UtteranceArchiveScreenSnapshot>,
        max_entries: usize,
    ) -> Result<UtteranceArchiveRecord, String> {
        self.ensure_layout().map_err(|error| error.to_string())?;
        let samples = audio.load_samples()?;
        if samples.is_empty() {
            return Err("empty audio".into());
        }

        let id = Uuid::new_v4();
        let id_hex = id.as_simple().to_string();
        let audio_path = format!("audio/{id_hex}.wav");
        let snapshot_path = snapshot.map(|_| format!("snapshots/{id_hex}.json"));

        let audio_seconds = samples.len() as f64 / TARGET_SAMPLE_RATE as f64;
        let record = UtteranceArchiveRecord {
            id,
            created_at: Utc::now(),
            outcome: metadata.outcome,
            error_message: metadata.error_message.clone(),
            model_id: metadata.model_id.clone(),
            language_id: metadata.language_id.clone(),
            audio_seconds,
            audio_path: audio_path.clone(),
            raw_text: metadata.raw_text.clone(),
            processed_text: metadata.processed_text.clone(),
            partial_transcription: metadata.partial_transcription.clone(),
            steering_terms: metadata.steering_terms.clone(),
            decoder_context_sha256: metadata.decoder_context_sha256.clone(),
            glossary_enabled: metadata.glossary_enabled,
            screen_context_enabled: metadata.screen_context_enabled,
            snapshot_path: snapshot_path.clone(),
            app_bundle_id: metadata.app_bundle_id.clone(),
            voicey_version: metadata.voicey_version.clone(),
            runtime: metadata.runtime.clone(),
        };

        write_mono_16k_pcm16(&samples, &self.root.join(&audio_path))
            .map_err(|error| error.to_string())?;

        if let (Some(snapshot), Some(snapshot_path)) = (snapshot, snapshot_path.as_ref()) {
            let data = serde_json::to_vec(snapshot).map_err(|error| error.to_string())?;
            fs::write(self.root.join(snapshot_path), data).map_err(|error| error.to_string())?;
        }

        self.append_index_line(&record).map_err(|error| error.to_string())?;
        self.apply_retention(max_entries).map_err(|error| error.to_string())?;
        Ok(record)
    }

    pub fn delete_all(&self) -> Result<(), String> {
        if self.root.exists() {
            fs::remove_dir_all(&self.root).map_err(|error| error.to_string())?;
        }
        self.ensure_layout().map_err(|error| error.to_string())?;
        Ok(())
    }

    fn index_path(&self) -> PathBuf {
        self.root.join(INDEX_FILE_NAME)
    }

    fn append_index_line(&self, record: &UtteranceArchiveRecord) -> io::Result<()> {
        let mut line = serde_json::to_string(record)?;
        line.push('\n');
        let path = self.index_path();
        if path.is_file() {
            let mut file = OpenOptions::new().append(true).open(path)?;
            file.write_all(line.as_bytes())?;
        } else {
            fs::write(path, line)?;
        }
        Ok(())
    }

    fn apply_retention(&self, max_entries: usize) -> io::Result<()> {
        let mut records = self.read_index()?;
        let evicted_ids = record_ids_to_evict(&records, max_entries);
        if evicted_ids.is_empty() {
            return Ok(());
        }
        let evicted: Vec<UtteranceArchiveRecord> = records
            .iter()
            .filter(|record| evicted_ids.contains(&record.id))
            .cloned()
            .collect();
        records.retain(|record| !evicted_ids.contains(&record.id));
        for record in evicted {
            let _ = fs::remove_file(self.root.join(&record.audio_path));
            if let Some(snapshot_path) = record.snapshot_path {
                let _ = fs::remove_file(self.root.join(snapshot_path));
            }
        }
        let mut body = String::new();
        for record in &records {
            body.push_str(&serde_json::to_string(record)?);
            body.push('\n');
        }
        fs::write(self.index_path(), body)?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::record::UtteranceArchiveOutcome;
    use tempfile::tempdir;

    #[test]
    fn append_and_read_round_trip() {
        let dir = tempdir().expect("tempdir");
        let store = SessionArchiveStore::new(dir.path());
        let metadata = AppendUtteranceMetadata {
            outcome: UtteranceArchiveOutcome::Completed,
            error_message: None,
            model_id: "qwen".into(),
            language_id: "en".into(),
            raw_text: "hi".into(),
            processed_text: "Hi".into(),
            partial_transcription: None,
            steering_terms: vec![],
            decoder_context_sha256: None,
            glossary_enabled: true,
            screen_context_enabled: false,
            app_bundle_id: None,
            voicey_version: Some("1.0".into()),
            runtime: Some("multiprocess".into()),
        };
        let audio = ArchiveAudioSource::Samples {
            samples: vec![0.0; 16_000],
        };
        store
            .append_utterance(&audio, &metadata, None, 500)
            .expect("append");
        let records = store.read_index().expect("read");
        assert_eq!(records.len(), 1);
        assert_eq!(records[0].processed_text, "Hi");
        assert!(dir.path().join(&records[0].audio_path).is_file());
    }
}
