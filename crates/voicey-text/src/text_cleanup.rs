//! Utilities for text cleanup and formatting in transcription output.

use regex::Regex;
use std::collections::HashMap;
use std::sync::LazyLock;

/// Default text normalizations for low-risk transcription artifacts.
pub fn default_text_expansions() -> HashMap<&'static str, &'static str> {
    HashMap::from([("o k", "OK")])
}

static PUNCTUATION_SPACING: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"([.!?,])([A-Za-z])").unwrap());

/// Capitalize the first character of a string.
pub fn capitalize_first(text: &str) -> String {
    let mut chars = text.chars();
    match chars.next() {
        None => text.to_string(),
        Some(first) => first.to_uppercase().collect::<String>() + chars.as_str(),
    }
}

/// Check if text starts with a conjunction.
pub fn is_conjunction(text: &str) -> bool {
    let conjunctions = [
        "and", "but", "or", "so", "yet", "for", "nor", "because", "although", "while", "if", "when",
    ];
    let first_word = text.split_whitespace().next().unwrap_or("").to_lowercase();
    conjunctions.contains(&first_word.as_str())
}

/// Apply text expansions to convert spoken phrases to written form.
pub fn apply_expansions(text: &str, expansions: &HashMap<&str, &str>) -> String {
    let mut result = text.to_string();
    for (spoken, written) in expansions {
        let pattern = format!(r"(?i)\b{}\b", regex::escape(spoken));
        if let Ok(re) = Regex::new(&pattern) {
            result = re.replace_all(&result, *written).into_owned();
        }
    }
    result
}

/// Ensure "I" is always capitalized.
pub fn capitalize_i(text: &str) -> String {
    let mut result = text.replace(" i ", " I ");
    result = result.replace(" i'", " I'");
    if result.starts_with("i ") {
        result = format!("I{}", &result[1..]);
    }
    result
}

/// Clean up spacing and punctuation issues.
pub fn cleanup_spacing_and_punctuation(text: &str) -> String {
    let mut result = text.to_string();

    while result.contains("  ") {
        result = result.replace("  ", " ");
    }

    result = result.replace(" .", ".");
    result = result.replace(" ,", ",");
    result = result.replace(" ?", "?");
    result = result.replace(" !", "!");

    result = result.replace("..", ".");
    result = result.replace(",,", ",");
    result = result.replace("....", "...");

    result = PUNCTUATION_SPACING
        .replace_all(&result, "$1 $2")
        .into_owned();

    result.trim().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_text_cleanup_does_not_rewrite_voice_command_defaults() {
        let text = "that is for example versus mister missus doctor okay etcetera et cetera";
        assert_eq!(apply_expansions(text, &default_text_expansions()), text);
    }

    #[test]
    fn default_expansions_normalize_spelled_out_ok() {
        assert_eq!(
            apply_expansions("that sounds o k to me", &default_text_expansions()),
            "that sounds OK to me"
        );
    }
}
