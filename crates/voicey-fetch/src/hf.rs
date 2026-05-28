//! Hugging Face model listing for Qwen MLX downloads (mirrors Swift `VoiceyRustQwenDownloader`).

const HF_HOST: &str = "https://huggingface.co";

#[derive(Debug, serde::Deserialize)]
struct TreeEntry {
    path: String,
    #[serde(rename = "type")]
    entry_type: String,
}

/// Maps Voicey `SpeechModel` raw values to Hugging Face repo ids.
pub fn hf_model_id(voicey_model_id: &str) -> Result<&'static str, String> {
    match voicey_model_id {
        "qwen3-asr-0.6b-6bit" => Ok("aufklarer/Qwen3-ASR-0.6B-MLX-4bit"),
        "qwen3-asr-1.7b-bf16" => Ok("aufklarer/Qwen3-ASR-1.7B-MLX-8bit"),
        other => Err(format!("unsupported model_id for HF download: {other}")),
    }
}

/// Lists remote weight files for a Voicey model id.
pub fn list_weight_files(voicey_model_id: &str) -> Result<Vec<String>, String> {
    let hf_id = hf_model_id(voicey_model_id)?;
    list_hf_repo_files(hf_id, default_globs())
}

fn default_globs() -> Vec<String> {
    vec![
        "config.json".into(),
        "*.safetensors".into(),
        "model.safetensors.index.json".into(),
        "vocab.json".into(),
        "merges.txt".into(),
        "tokenizer_config.json".into(),
    ]
}

pub fn list_hf_repo_files(hf_id: &str, globs: Vec<String>) -> Result<Vec<String>, String> {
    let encoded = hf_id.replace('/', "%2F");
    let url = format!("{HF_HOST}/api/models/{encoded}/tree/main?recursive=1");
    let client = reqwest::blocking::Client::builder()
        .user_agent("voicey-fetch/0.1")
        .build()
        .map_err(|error| error.to_string())?;
    let response = client
        .get(&url)
        .send()
        .map_err(|error| error.to_string())?;
    if !response.status().is_success() {
        return Err(format!("HF tree HTTP {}", response.status()));
    }
    let entries: Vec<TreeEntry> = response.json().map_err(|error| error.to_string())?;
    let mut matched: Vec<String> = entries
        .into_iter()
        .filter(|entry| entry.entry_type == "file")
        .map(|entry| entry.path)
        .filter(|path| globs.iter().any(|glob| glob_matches(glob, path)))
        .collect();
    matched.sort();
    matched.dedup();
    if matched.is_empty() {
        return Err(format!("{hf_id}: no files matched"));
    }
    Ok(matched)
}

pub fn resolve_file_url(hf_id: &str, relative_path: &str) -> String {
    format!("{HF_HOST}/{hf_id}/resolve/main/{relative_path}")
}

pub fn glob_matches(glob: &str, path: &str) -> bool {
    if glob == path {
        return true;
    }
    if glob.starts_with("*.") {
        let suffix = &glob[1..];
        return path.ends_with(suffix);
    }
    if glob == "*.safetensors" {
        return path.ends_with(".safetensors");
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hf_model_id_maps_qwen_variants() {
        assert_eq!(
            hf_model_id("qwen3-asr-0.6b-6bit").expect("small"),
            "aufklarer/Qwen3-ASR-0.6B-MLX-4bit"
        );
    }

    #[test]
    fn glob_matches_safetensors_and_exact() {
        assert!(glob_matches("config.json", "config.json"));
        assert!(glob_matches("*.safetensors", "model.safetensors"));
        assert!(!glob_matches("config.json", "other.json"));
    }
}
