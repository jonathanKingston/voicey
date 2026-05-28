//! Constants and logic for filtering noise words from transcription output.

use regex::Regex;
use std::sync::LazyLock;

static NOISE_PATTERNS: LazyLock<Vec<Regex>> = LazyLock::new(|| {
    [
        r"(?i)^\s*\*[^*]+\*\s*$",
        r"(?i)^\s*\[[^\]]+\]\s*$",
        r"(?i)^\s*\([^)]+\)\s*$",
        r"(?i)^\s*\.+\s*$",
        r"(?i)^\s*…+\s*$",
    ]
    .iter()
    .filter_map(|pattern| Regex::new(pattern).ok())
    .collect()
});

static TRAILING_REPEATED_ARTIFACT_PATTERNS: LazyLock<Vec<Regex>> = LazyLock::new(|| {
    [
        r"(?i)(?:\bthank you\b[\s,.!?]*){2,}$",
        r"(?i)(?:\bthanks\b[\s,.!?]*){2,}$",
        r"(?i)(?:\bthanks you\b[\s,.!?]*){2,}$",
    ]
    .iter()
    .filter_map(|pattern| Regex::new(pattern).ok())
    .collect()
});

/// Words/phrases that Whisper often outputs for non-speech sounds.
pub const NOISE_WORDS: &[&str] = &["...", "…"];

/// Keywords that indicate a bracketed annotation is noise.
pub const NOISE_ANNOTATION_KEYWORDS: &[&str] = &[
    "music",
    "noise",
    "silence",
    "inaudible",
    "unintelligible",
    "typing",
    "keyboard",
    "applause",
];

/// Check if a bracketed text looks like a noise annotation.
pub fn is_noise_annotation(text: &str) -> bool {
    let lowercased = text.to_lowercase();
    NOISE_ANNOTATION_KEYWORDS
        .iter()
        .any(|keyword| lowercased.contains(keyword))
}

/// Check if entire text matches a noise pattern.
pub fn matches_noise_pattern(text: &str) -> bool {
    NOISE_PATTERNS
        .iter()
        .any(|regex| regex.is_match(text))
}

/// Remove repeated hallucinated phrase endings (for example: "thank you thank you").
pub fn remove_trailing_repeated_artifacts(text: &str) -> String {
    let mut result = text.to_string();
    for regex in TRAILING_REPEATED_ARTIFACT_PATTERNS.iter() {
        result = regex.replace(&result, "").into_owned();
    }
    result.trim().to_string()
}

/// Filter noise words, bracketed annotations, and asterisk-wrapped words from text.
pub fn filter_noise(text: &str) -> String {
    if matches_noise_pattern(text) {
        return String::new();
    }

    let mut result = text.to_string();
    result = remove_noise_words(&result);
    result = remove_bracketed_annotations(&result);
    result = remove_asterisk_wrapped_words(&result);
    remove_trailing_repeated_artifacts(&result)
}

fn remove_noise_words(text: &str) -> String {
    let mut result = text.to_string();
    for noise_word in NOISE_WORDS {
        let pattern = format!(
            r"(?i)(?:^|\s)\*?{}\*?[.,!?]*(?:\s|$)",
            regex::escape(noise_word)
        );
        if let Ok(re) = Regex::new(&pattern) {
            result = re.replace_all(&result, " ").into_owned();
        }
    }
    result
}

fn remove_bracketed_annotations(text: &str) -> String {
    let mut result = text.to_string();
    let bracket_patterns = [r"(?i)\[[^\]]*\]", r"(?i)\([^)]*\)"];

    for pattern in bracket_patterns {
        let Ok(re) = Regex::new(pattern) else {
            continue;
        };
        let ranges: Vec<_> = re
            .find_iter(&result)
            .filter(|m| is_noise_annotation(m.as_str()))
            .map(|m| m.range())
            .collect();
        for range in ranges.into_iter().rev() {
            result.replace_range(range, "");
        }
    }
    result
}

fn remove_asterisk_wrapped_words(text: &str) -> String {
    let Ok(re) = Regex::new(r"(?i)\*[^*]+\*") else {
        return text.to_string();
    };
    re.replace_all(text, "").into_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn matches_whole_text_noise_patterns() {
        assert!(matches_noise_pattern("..."));
        assert!(matches_noise_pattern("*music*"));
        assert!(matches_noise_pattern("[music]"));
        assert!(matches_noise_pattern("(typing)"));
        assert!(matches_noise_pattern("...."));
        assert!(!matches_noise_pattern("hello world"));
    }

    #[test]
    fn removes_noise_words_from_text() {
        assert_eq!(filter_noise("hello ... world"), "hello world");
        assert_eq!(filter_noise("hello … world"), "hello world");
    }

    #[test]
    fn removes_bracketed_noise_annotations() {
        assert_eq!(filter_noise("[music] hello"), "hello");
        assert_eq!(filter_noise("hello (typing) there"), "hello  there");
        assert_eq!(filter_noise("hello (laughter) there"), "hello (laughter) there");
    }

    #[test]
    fn removes_asterisk_wrapped_words() {
        assert_eq!(filter_noise("*laughs* hello"), "hello");
    }

    #[test]
    fn removes_trailing_repeated_artifacts() {
        assert_eq!(filter_noise("thank you thank you"), "");
        assert_eq!(filter_noise("hello thank you thank you"), "hello");
        assert_eq!(filter_noise("thanks thanks"), "");
    }

    #[test]
    fn whole_text_noise_returns_empty() {
        assert_eq!(filter_noise("*music*"), "");
        assert_eq!(filter_noise("[silence]"), "");
    }
}
