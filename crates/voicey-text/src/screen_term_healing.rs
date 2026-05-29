//! Repairs split or clipped OCR tokens using on-screen vocabulary.

use crate::screen_term_filter::{self, MAX_TOKEN_LENGTH, MIN_TOKEN_LENGTH};
use regex::Regex;
use std::sync::LazyLock;

/// Max characters missing from the start of a vocabulary word when matching a clipped OCR token.
pub const MAX_MISSING_PREFIX_LENGTH: usize = 3;

static LEXICAL_PATTERN: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"[A-Za-z0-9][A-Za-z0-9\-_'/]*[A-Za-z0-9]|[A-Za-z0-9]").unwrap());

struct LexicalPiece {
    string: String,
    start: usize,
    end: usize,
}

/// Tokens split across whitespace/punctuation in OCR (e.g. `st` + `ream` → `stream`).
pub fn merged_adjacent_tokens(text: &str) -> Vec<String> {
    let pieces = lexical_pieces(text);
    if pieces.len() < 2 {
        return Vec::new();
    }

    let mut merged = Vec::new();
    for index in 0..(pieces.len() - 1) {
        let left = &pieces[index];
        let right = &pieces[index + 1];
        let gap_start = left.end;
        let gap_end = right.start;
        if !is_mergeable_gap(text, gap_start, gap_end) {
            continue;
        }
        if left.string.len() > 4 || right.string.len() > 4 {
            continue;
        }
        if left.string.len() > 3 && right.string.len() > 3 {
            continue;
        }

        let gap = &text[gap_start..gap_end];
        let combined = format!("{}{}", left.string, right.string);
        if combined.len() < MIN_TOKEN_LENGTH
            || combined.len() > MAX_TOKEN_LENGTH
            || !appears_as_merged_form(&combined, &left.string, &right.string, gap, text)
        {
            continue;
        }
        merged.push(combined);
    }
    merged
}

/// Maps a clipped token to a full anchor word when it matches a short missing prefix.
pub fn anchor_completion(token: &str, anchors: &[String]) -> Option<String> {
    let trimmed = token.trim();
    if trimmed.len() < MIN_TOKEN_LENGTH {
        return None;
    }
    let lower = trimmed.to_lowercase();

    for anchor in anchors {
        let anchor_lower = anchor.to_lowercase();
        if anchor_lower.len() <= lower.len() {
            continue;
        }
        let missing = anchor_lower.len() - lower.len();
        if missing <= MAX_MISSING_PREFIX_LENGTH && anchor_lower.ends_with(&lower) {
            return Some(anchor.clone());
        }
    }
    None
}

/// True when `token` is a strict substring of an anchor and cannot be completed (interior OCR clip).
pub fn is_interior_fragment(token: &str, anchors: &[String]) -> bool {
    if anchor_completion(token, anchors).is_some() {
        return false;
    }

    let lower = token.to_lowercase();
    if lower.len() < MIN_TOKEN_LENGTH {
        return true;
    }

    for anchor in anchors {
        let anchor_lower = anchor.to_lowercase();
        if anchor_lower.len() <= lower.len() || !anchor_lower.contains(&lower) {
            continue;
        }
        if anchor_lower.ends_with(&lower)
            && anchor_lower.len() - lower.len() <= MAX_MISSING_PREFIX_LENGTH
        {
            return false;
        }
        return true;
    }
    false
}

/// Single-token and merged adjacent tokens, with anchor completion applied when possible.
pub fn enriched_tokens(text: &str, anchors: &[String]) -> Vec<String> {
    let mut seen = std::collections::HashSet::new();
    let mut result = Vec::new();

    for token in screen_term_filter::tokenize(text) {
        push_enriched_token(&mut seen, &mut result, &token, anchors, text);
    }
    for merged in merged_adjacent_tokens(text) {
        push_enriched_token(&mut seen, &mut result, &merged, anchors, text);
    }
    result
}

fn push_enriched_token(
    seen: &mut std::collections::HashSet<String>,
    result: &mut Vec<String>,
    raw: &str,
    anchors: &[String],
    text: &str,
) {
    let canonical = anchor_completion(raw, anchors).unwrap_or_else(|| raw.to_string());
    if !screen_term_filter::appears_with_word_boundaries(&canonical, text) {
        return;
    }
    if screen_term_filter::is_steering_noise_token(&canonical) {
        return;
    }
    let key = canonical.to_lowercase();
    if seen.contains(&key) {
        return;
    }
    seen.insert(key);
    result.push(canonical);
}

pub fn canonical_term(term: &str, anchors: &[String]) -> String {
    anchor_completion(term, anchors).unwrap_or_else(|| term.to_string())
}

fn lexical_pieces(text: &str) -> Vec<LexicalPiece> {
    LEXICAL_PATTERN
        .find_iter(text)
        .map(|m| LexicalPiece {
            string: m.as_str().to_string(),
            start: m.start(),
            end: m.end(),
        })
        .collect()
}

fn appears_as_merged_form(combined: &str, left: &str, right: &str, gap: &str, text: &str) -> bool {
    if screen_term_filter::appears_with_word_boundaries(combined, text) {
        return true;
    }
    if gap.chars().any(char::is_whitespace) {
        return false;
    }
    let tight = format!("{left}{gap}{right}");
    text.to_lowercase().contains(&tight.to_lowercase())
}

fn is_mergeable_gap(text: &str, start: usize, end: usize) -> bool {
    if start > end {
        return false;
    }
    let gap = &text[start..end];
    if gap.chars().any(char::is_whitespace) {
        return false;
    }
    gap.chars().all(|c| !c.is_alphanumeric())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn merged_adjacent_tokens_rejoins_split_word() {
        let merged = merged_adjacent_tokens("log st,ream here");
        assert!(merged.iter().any(|m| m == "stream"));
    }

    #[test]
    fn merged_adjacent_tokens_ignores_space_separated_pieces() {
        let merged = merged_adjacent_tokens("log st ream here");
        assert!(!merged.iter().any(|m| m == "stream"));
        assert!(!merged.iter().any(|m| m == "logstream"));
    }

    #[test]
    fn anchor_completion_fixes_missing_prefix() {
        let anchors = vec!["transcription".to_string(), "Voicey".to_string()];
        assert_eq!(
            anchor_completion("ranscription", &anchors),
            Some("transcription".to_string())
        );
    }

    #[test]
    fn interior_fragment_dropped() {
        let anchors = vec!["transcription".to_string()];
        assert!(is_interior_fragment("script", &anchors));
        assert!(!is_interior_fragment("ranscription", &anchors));
    }
}
