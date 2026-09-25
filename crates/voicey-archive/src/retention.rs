use crate::record::UtteranceArchiveRecord;
use uuid::Uuid;

pub fn record_ids_to_evict(records: &[UtteranceArchiveRecord], max_entries: usize) -> Vec<Uuid> {
    if max_entries == 0 || records.len() <= max_entries {
        return Vec::new();
    }
    let mut sorted: Vec<&UtteranceArchiveRecord> = records.iter().collect();
    sorted.sort_by_key(|record| record.created_at);
    let overflow = sorted.len() - max_entries;
    sorted
        .into_iter()
        .take(overflow)
        .map(|record| record.id)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::record::{UtteranceArchiveOutcome, UtteranceArchiveRecord};
    use chrono::TimeZone;
    use uuid::Uuid;

    fn sample_record(at_seconds: u32) -> UtteranceArchiveRecord {
        UtteranceArchiveRecord {
            id: Uuid::new_v4(),
            created_at: chrono::Utc.with_ymd_and_hms(2025, 1, 1, 0, 0, at_seconds).unwrap(),
            outcome: UtteranceArchiveOutcome::Completed,
            error_message: None,
            model_id: "m".into(),
            language_id: "auto".into(),
            audio_seconds: 1.0,
            audio_path: "audio/x.wav".into(),
            audio_format: crate::record::default_audio_format(),
            raw_text: String::new(),
            processed_text: "x".into(),
            partial_transcription: None,
            steering_terms: Vec::new(),
            decoder_context_sha256: None,
            glossary_enabled: false,
            screen_context_enabled: false,
            snapshot_path: None,
            app_bundle_id: None,
            voicey_version: None,
            runtime: None,
        }
    }

    #[test]
    fn evicts_oldest_first() {
        let records = vec![
            sample_record(0),
            sample_record(1),
            sample_record(2),
        ];
        let oldest = records[0].id;
        let evicted = record_ids_to_evict(&records, 2);
        assert_eq!(evicted, vec![oldest]);
    }
}
