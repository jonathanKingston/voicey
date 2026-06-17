//! Deterministic inverse text normalization for spoken-form dictation.

use regex::Regex;
use std::sync::LazyLock;

static COMPOUND_WORDS: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)\b(to morrow|to day|to night|every one|some one|any one|home made)\b").unwrap()
});

static SPOKEN_TITLES: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)\b(mister|missus|doctor)\b").unwrap()
});

/// Apply conservative ITN rules. Intended for prose dictation, not code editors.
pub fn apply_itn(text: &str) -> String {
    let mut result = text.to_string();
    result = COMPOUND_WORDS
        .replace_all(&result, |caps: &regex::Captures| {
            match caps[1].to_ascii_lowercase().as_str() {
                "to morrow" => "tomorrow".to_string(),
                "to day" => "today".to_string(),
                "to night" => "tonight".to_string(),
                "every one" => "everyone".to_string(),
                "some one" => "someone".to_string(),
                "any one" => "anyone".to_string(),
                "home made" => "homemade".to_string(),
                _ => caps[0].to_string(),
            }
        })
        .into_owned();
    result = SPOKEN_TITLES
        .replace_all(&result, |caps: &regex::Captures| {
            match caps[1].to_ascii_lowercase().as_str() {
                "mister" => "Mr.".to_string(),
                "missus" => "Mrs.".to_string(),
                "doctor" => "Dr.".to_string(),
                _ => caps[0].to_string(),
            }
        })
        .into_owned();
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalizes_spoken_compounds() {
        assert_eq!(
            apply_itn("See you to morrow for home made bread."),
            "See you tomorrow for homemade bread."
        );
    }

    #[test]
    fn normalizes_spoken_titles() {
        assert_eq!(
            apply_itn("mister Swift arrived with doctor Smith."),
            "Mr. Swift arrived with Dr. Smith."
        );
    }
}
