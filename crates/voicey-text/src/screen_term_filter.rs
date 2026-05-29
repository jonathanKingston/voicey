//! Filters and tokenizes text for screen-context term selection.

use regex::Regex;
use std::sync::LazyLock;

pub const MIN_TOKEN_LENGTH: usize = 2;
pub const MAX_TOKEN_LENGTH: usize = 64;

static TOKEN_PATTERN: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"[A-Za-z0-9][A-Za-z0-9\-_'/]*[A-Za-z0-9]|[A-Za-z0-9]").unwrap());

static FOUR_PLUS_DIGITS: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\d{4,}").unwrap());

static DATE_PATTERN: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"\d{4}-\d{1,2}-\d{1,2}").unwrap());

static TIME_PATTERN: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"\d{1,2}:\d{2}(:\d{2})?").unwrap());

static YEAR_PATTERN: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^\d{4}$").unwrap());

fn stopwords() -> &'static [&'static str] {
    &[
        "a", "an", "and", "are", "as", "at", "be", "but", "by", "for", "from", "had", "has",
        "have", "he", "her", "his", "i", "if", "in", "is", "it", "its", "me", "my", "not", "of",
        "on", "or", "our", "she", "so", "that", "the", "their", "them", "there", "they", "this",
        "to", "was", "we", "were", "what", "when", "which", "who", "will", "with", "you", "your",
    ]
}

fn ui_chrome() -> &'static [&'static str] {
    &[
        "about",
        "add",
        "back",
        "cancel",
        "close",
        "copy",
        "cut",
        "delete",
        "done",
        "edit",
        "file",
        "forward",
        "help",
        "home",
        "menu",
        "more",
        "new",
        "next",
        "ok",
        "open",
        "paste",
        "preferences",
        "redo",
        "refresh",
        "remove",
        "save",
        "search",
        "settings",
        "share",
        "stop",
        "tools",
        "undo",
        "view",
        "window",
        "zoom",
    ]
}

fn path_fragments() -> &'static [&'static str] {
    &[
        "tmp",
        "usr",
        "bin",
        "private",
        "var",
        "predicate",
        "subsystem",
    ]
}

fn is_stopword_or_chrome(lower: &str) -> bool {
    stopwords().contains(&lower) || ui_chrome().contains(&lower)
}

/// True when `term` appears in `text` with non-alphanumeric boundaries (not glued across a space).
pub fn appears_with_word_boundaries(term: &str, text: &str) -> bool {
    let trimmed = term.trim();
    if trimmed.is_empty() {
        return false;
    }

    let escaped = regex::escape(trimmed);
    let pattern = format!(r"(?i)\b{escaped}\b");
    Regex::new(&pattern)
        .map(|re| re.is_match(text))
        .unwrap_or(false)
}

pub fn tokenize(text: &str) -> Vec<String> {
    TOKEN_PATTERN
        .find_iter(text)
        .filter_map(|m| {
            let token = m.as_str();
            if token.len() < MIN_TOKEN_LENGTH || token.len() > MAX_TOKEN_LENGTH {
                return None;
            }
            let normalized = token.to_lowercase();
            if is_stopword_or_chrome(&normalized) {
                return None;
            }
            Some(token.to_string())
        })
        .collect()
}

pub fn is_noise_chunk(text: &str) -> bool {
    let trimmed = text.trim();
    if trimmed.len() < 8 {
        return true;
    }
    tokenize(trimmed).is_empty()
}

/// Drops numeric/log/OCR junk and generic tokens from decoder steering glossaries.
pub fn is_steering_noise_token(token: &str) -> bool {
    let trimmed = token.trim();
    if trimmed.is_empty() {
        return true;
    }

    if trimmed.len() <= 2 {
        return true;
    }

    let lower = trimmed.to_lowercase();
    if is_stopword_or_chrome(&lower) {
        return true;
    }

    if trimmed.chars().all(|c| c.is_ascii_digit()) {
        return true;
    }

    if trimmed.len() >= 5 && trimmed.chars().all(|c| c.is_ascii_hexdigit()) {
        return true;
    }

    if FOUR_PLUS_DIGITS.is_match(trimmed) {
        let letter_count = trimmed.chars().filter(|c| c.is_ascii_alphabetic()).count();
        let digit_count = trimmed.chars().filter(|c| c.is_ascii_digit()).count();
        if digit_count >= 4 && letter_count > 0 && letter_count <= 12 {
            return true;
        }
    }

    if path_fragments().contains(&lower.as_str()) {
        return true;
    }

    if lower.starts_with("voicey") && trimmed.chars().filter(|c| c.is_ascii_digit()).count() >= 3 {
        return true;
    }

    if is_date_or_time_token(trimmed) {
        return true;
    }

    false
}

pub fn is_date_or_time_token(token: &str) -> bool {
    if DATE_PATTERN.is_match(token) {
        return true;
    }
    if TIME_PATTERN.is_match(token) {
        return true;
    }
    if YEAR_PATTERN.is_match(token) {
        return true;
    }
    if token
        .chars()
        .all(|c| c.is_ascii_digit() || c == '-' || c == ':' || c == '/')
    {
        return true;
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn appears_with_word_boundaries_rejects_glued_substring() {
        assert!(!appears_with_word_boundaries("stream", "log st ream"));
        assert!(appears_with_word_boundaries("stream", "watch stream live"));
    }

    #[test]
    fn date_tokens_are_noise() {
        assert!(is_steering_noise_token("2026-05-27"));
        assert!(is_steering_noise_token("18:44:54"));
    }
}
