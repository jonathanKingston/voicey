use std::io::{self, BufReader};

fn main() {
    if let Err(error) = voicey_archive::worker::run_jsonl_loop(BufReader::new(io::stdin()), io::stdout())
    {
        eprintln!("voicey-archive fatal: {error}");
        std::process::exit(1);
    }
}
