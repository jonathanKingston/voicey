//! Text post-processing worker — JSONL on stdin/stdout.

fn main() {
    if let Err(error) =
        voicey_text::worker::run_jsonl_loop(std::io::stdin().lock(), std::io::stdout())
    {
        eprintln!("voicey-text fatal: {error}");
        std::process::exit(1);
    }
}
