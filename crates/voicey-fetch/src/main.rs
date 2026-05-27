//! Staging download worker — JSONL on stdin/stdout (invoked by supervisor or standalone).

mod manifest;
mod worker;

fn main() {
    if let Err(error) = worker::run_jsonl_loop(std::io::stdin().lock(), std::io::stdout()) {
        eprintln!("voicey-fetch fatal: {error}");
        std::process::exit(1);
    }
}
