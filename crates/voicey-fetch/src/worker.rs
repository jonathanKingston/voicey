use crate::manifest::{
    download_to_staging, promote_staging, FetchRequest, FetchResponse, ManifestFile,
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
        let json = serde_json::to_string(&response).map_err(|e| {
            std::io::Error::new(std::io::ErrorKind::InvalidData, e)
        })?;
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
        FetchRequest::DownloadHfFile {
            id,
            url,
            staging_path,
            expected_sha256,
        } => match download_to_staging(&url, staging_path.as_ref(), expected_sha256.as_deref()) {
            Ok(_) => FetchResponse::Ok { id },
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
        } => match promote_staging(
            staging_path.as_ref(),
            final_path.as_ref(),
            &manifest,
        ) {
            Ok(()) => FetchResponse::Ok { id },
            Err(error) => FetchResponse::Error {
                id,
                message: error.to_string(),
            },
        },
        FetchRequest::Shutdown { id } => FetchResponse::Ok { id },
    }
}
