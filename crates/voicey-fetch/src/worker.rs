use crate::manifest::{
    download_model_file, list_model_files, promote_staging, FetchRequest, FetchResponse,
};
use std::io::{BufRead, Write};

pub fn run_jsonl_loop(mut input: impl BufRead, mut output: impl Write) -> std::io::Result<()> {
    let mut line = String::new();
    loop {
        line.clear();
        let read = input.read_line(&mut line)?;
        if read == 0 {
            break;
        }
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        let response = handle_line(trimmed);
        let json = serde_json::to_string(&response)
            .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
        writeln!(output, "{json}")?;
        output.flush()?;
        if matches!(response, FetchResponse::Ok { .. }) {
            if let Ok(FetchRequest::Shutdown { .. }) = serde_json::from_str(trimmed) {
                break;
            }
        }
    }
    Ok(())
}

fn handle_line(line: &str) -> FetchResponse {
    let request: FetchRequest = match serde_json::from_str(line) {
        Ok(value) => value,
        Err(error) => {
            return FetchResponse::Error {
                id: String::new(),
                message: format!("invalid request: {error}"),
            }
        }
    };

    match request {
        FetchRequest::Ping { id } => FetchResponse::Pong { id },
        FetchRequest::ListModelFiles {
            id,
            model_id,
            revision,
            patterns,
        } => match list_model_files(&model_id, revision.as_deref(), &patterns) {
            Ok(files) => FetchResponse::ListedModelFiles { id, files },
            Err(error) => FetchResponse::Error {
                id,
                message: error.to_string(),
            },
        },
        FetchRequest::DownloadModelFile {
            id,
            model_id,
            revision,
            relative_path,
            model_root,
            expected_sha256,
        } => match download_model_file(
            &model_id,
            revision.as_deref(),
            &relative_path,
            &model_root,
            expected_sha256.as_deref(),
        ) {
            Ok(path) => FetchResponse::DownloadedModelFile {
                id,
                staged_path: path.display().to_string(),
            },
            Err(error) => FetchResponse::Error {
                id,
                message: error.to_string(),
            },
        },
        FetchRequest::PromoteStaging {
            id,
            staging_path,
            final_path,
            manifest,
        } => match promote_staging(staging_path.as_ref(), final_path.as_ref(), &manifest) {
            Ok(()) => FetchResponse::Ok { id },
            Err(error) => FetchResponse::Error {
                id,
                message: error.to_string(),
            },
        },
        FetchRequest::Shutdown { id } => FetchResponse::Ok { id },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn list_model_files_rejects_voicey_slug_model_id() {
        let response = handle_line(
            r#"{"type":"list_model_files","id":"1","model_id":"qwen3-asr-0.6b-6bit","revision":"main","patterns":["config.json"]}"#,
        );
        assert!(matches!(response, FetchResponse::Error { .. }));
    }

    #[test]
    fn download_model_file_rejects_voicey_slug_model_id() {
        let response = handle_line(
            r#"{"type":"download_model_file","id":"1","model_id":"qwen3-asr-0.6b-6bit","relative_path":"config.json","model_root":"/tmp/models"}"#,
        );
        assert!(matches!(response, FetchResponse::Error { .. }));
    }

    #[test]
    fn download_model_file_accepts_hf_repo_id_format() {
        let hf_id = voicey_protocol::hugging_face_repo_id("qwen3-asr-0.6b-6bit").expect("hf id");
        let response = handle_line(&format!(
            r#"{{"type":"download_model_file","id":"1","model_id":"{hf_id}","relative_path":"config.json","model_root":"/tmp/models"}}"#
        ));
        // Network may fail; ensure we got past model_id validation (not invalid model_id).
        match response {
            FetchResponse::Error { message, .. } => {
                assert!(
                    !message.contains("invalid model_id"),
                    "unexpected validation error: {message}"
                );
            }
            FetchResponse::DownloadedModelFile { .. } => {}
            other => panic!("unexpected response: {other:?}"),
        }
    }
}
