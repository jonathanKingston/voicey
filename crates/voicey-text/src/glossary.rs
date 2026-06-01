//! Builds decoder context strings for on-device ASR vocabulary biasing.

use crate::screen_term_filter;
use crate::screen_term_selector;
use std::collections::HashSet;

/// Upper bound on glossary context length passed to the model.
pub const MAX_CONTEXT_CHARACTER_COUNT: usize = 2000;

/// Always included in steering glossaries when biasing is enabled.
pub const BUILT_IN_TERMS: &[&str] = &["Voicey"];

/// Minimum content tokens before the steering-overlap guard may clear output. Below
/// this, short legitimate dictation of a biased term the user actually said is kept.
pub const MINIMUM_OVERLAP_TOKEN_COUNT: usize = 3;

/// Fraction of content tokens that must be steering vocabulary for output to be treated
/// as regurgitated steering "soup" and cleared.
pub const STEERING_OVERLAP_CLEAR_THRESHOLD: f64 = 0.8;

/// Returns decoder context for the combined term list, or `None` when empty.
pub fn decoding_context(terms: &[String]) -> Option<String> {
    let merged: Vec<String> = BUILT_IN_TERMS
        .iter()
        .map(|s| (*s).to_string())
        .chain(terms.iter().cloned())
        .collect();
    let unique = screen_term_selector::dedupe_preserving_order(
        &merged,
        screen_term_selector::DEFAULT_MAX_TERMS,
    );
    if unique.is_empty() {
        return None;
    }
    Some(format_terms(&unique))
}

/// Returns decoder context when only a manual glossary is enabled.
pub fn decoding_context_enabled(enabled: bool, raw_glossary: &str) -> Option<String> {
    if !enabled {
        return None;
    }
    decoding_context(&parse_terms(raw_glossary))
}

/// Normalizes user glossary text into a Qwen decoder context prefix.
pub fn format(raw: &str) -> String {
    format_terms(&parse_terms(raw))
}

/// Formats an ordered term list into decoder context.
pub fn format_terms(terms: &[String]) -> String {
    if terms.is_empty() {
        return String::new();
    }

    let joined = terms.join(", ");
    let body = format!("Glossary: {joined}");
    if body.len() <= MAX_CONTEXT_CHARACTER_COUNT {
        return body;
    }
    body.chars().take(MAX_CONTEXT_CHARACTER_COUNT).collect()
}

/// Removes decoder steering text when the model echoes the (glossary-only) decoder
/// context instead of transcribing speech.
pub fn stripping_echoed_decoder_context(text: &str, decoder_context: Option<&str>) -> String {
    let Some(decoder_context) = decoder_context else {
        return text.to_string();
    };
    let normalized_context = decoder_context.trim();
    if normalized_context.is_empty() {
        return text.to_string();
    }

    let remainder = text.trim();
    if remainder.is_empty() {
        return remainder.to_string();
    }

    if remainder == normalized_context {
        return String::new();
    }
    if let Some(rest) = remainder.strip_prefix(normalized_context) {
        let rest = rest.trim_start();
        let rest = rest.strip_prefix([',', ':']).unwrap_or(rest);
        return rest.trim().to_string();
    }
    remainder.to_string()
}

/// Outcome of [`sanitize_steering_echo`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SanitizeResult {
    /// Transcript with regurgitated steering vocabulary removed.
    pub text: String,
    /// True when non-empty input was cleared because it was a steering echo.
    pub cleared: bool,
}

/// Removes regurgitated steering vocabulary (glossary + screen-context terms) from a
/// transcript before delivery/paste.
///
/// Runs the verbatim prefix/exact echo strip ([`stripping_echoed_decoder_context`]) and a
/// steering-term overlap guard that catches reordered, partial, or non-prefix echoes (the
/// "screen-term soup" case). Normal dictation with incidental term overlap is preserved.
pub fn sanitize_steering_echo(
    text: &str,
    decoder_context: Option<&str>,
    steering_terms: &[String],
) -> SanitizeResult {
    let had_input = !text.trim().is_empty();

    let stripped = stripping_echoed_decoder_context(text, decoder_context);
    let remainder = stripped.trim();
    if remainder.is_empty() {
        return SanitizeResult {
            text: stripped.clone(),
            cleared: had_input,
        };
    }

    if is_steering_soup(remainder, decoder_context, steering_terms) {
        return SanitizeResult {
            text: String::new(),
            cleared: true,
        };
    }

    SanitizeResult {
        text: stripped,
        cleared: false,
    }
}

/// True when `text` is composed almost entirely of steering vocabulary, indicating the
/// model echoed the glossary/screen terms rather than transcribing speech.
fn is_steering_soup(
    text: &str,
    decoder_context: Option<&str>,
    steering_terms: &[String],
) -> bool {
    let steering_tokens = steering_token_set(decoder_context, steering_terms);
    if steering_tokens.is_empty() {
        return false;
    }

    let tokens: Vec<String> = screen_term_filter::tokenize(text)
        .into_iter()
        .map(|token| token.to_lowercase())
        .collect();
    if tokens.len() < MINIMUM_OVERLAP_TOKEN_COUNT {
        return false;
    }

    let matches = tokens
        .iter()
        .filter(|token| steering_tokens.contains(*token))
        .count();
    let ratio = matches as f64 / tokens.len() as f64;
    ratio >= STEERING_OVERLAP_CLEAR_THRESHOLD
}

/// Lowercased token set covering the built-in terms, supplied steering terms, and the
/// decoder context label (e.g. `glossary`).
fn steering_token_set(decoder_context: Option<&str>, steering_terms: &[String]) -> HashSet<String> {
    let mut tokens = HashSet::new();
    for term in BUILT_IN_TERMS
        .iter()
        .map(|term| (*term).to_string())
        .chain(steering_terms.iter().cloned())
    {
        for token in screen_term_filter::tokenize(&term) {
            tokens.insert(token.to_lowercase());
        }
    }
    if let Some(context) = decoder_context {
        for token in screen_term_filter::tokenize(context) {
            tokens.insert(token.to_lowercase());
        }
    }
    tokens
}

/// Splits comma- or newline-separated glossary entries.
pub fn parse_terms(raw: &str) -> Vec<String> {
    raw.split([',', '\n'])
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(String::from)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decoding_context_disabled_returns_none() {
        assert!(decoding_context_enabled(false, "Metformin").is_none());
    }

    #[test]
    fn decoding_context_empty_glossary_returns_built_in() {
        assert_eq!(
            decoding_context_enabled(true, "  \n  "),
            Some("Glossary: Voicey".to_string())
        );
    }

    #[test]
    fn decoding_context_always_includes_built_in_voicey() {
        assert_eq!(
            decoding_context(&["Metformin".to_string()]),
            Some("Glossary: Voicey, Metformin".to_string())
        );
    }

    #[test]
    fn decoding_context_merges_manual_and_screen_terms() {
        let context = decoding_context(&[
            "Voicey".to_string(),
            "metformin".to_string(),
            "Voicey".to_string(),
        ]);
        assert_eq!(context, Some("Glossary: Voicey, metformin".to_string()));
    }

    #[test]
    fn format_comma_separated_terms() {
        assert_eq!(
            format("Metformin, HbA1c, nephropathy"),
            "Glossary: Metformin, HbA1c, nephropathy"
        );
    }

    #[test]
    fn format_newline_separated_terms() {
        assert_eq!(
            format("QuirkQuid\nP3-Quattro\nO3-Omni"),
            "Glossary: QuirkQuid, P3-Quattro, O3-Omni"
        );
    }

    #[test]
    fn format_truncates_long_glossary() {
        let long_term = "a".repeat(MAX_CONTEXT_CHARACTER_COUNT);
        let formatted = format(&long_term);
        assert_eq!(formatted.len(), MAX_CONTEXT_CHARACTER_COUNT);
        assert!(formatted.starts_with("Glossary: "));
    }

    #[test]
    fn strip_echoed_decoder_context_exact_match() {
        let context = "Glossary: Voicey";
        assert_eq!(
            stripping_echoed_decoder_context("Glossary: Voicey", Some(context)),
            ""
        );
    }

    #[test]
    fn strip_echoed_decoder_context_keeps_speech() {
        let context = "Glossary: Voicey";
        assert_eq!(
            stripping_echoed_decoder_context("Hello world", Some(context)),
            "Hello world"
        );
    }

    fn sample_terms() -> Vec<String> {
        vec![
            "Cursor".to_string(),
            "metformin".to_string(),
            "HbA1c".to_string(),
        ]
    }

    #[test]
    fn sanitize_keeps_normal_dictation() {
        let context = "Glossary: Voicey, Cursor, metformin, HbA1c";
        let result = sanitize_steering_echo(
            "Hello world, how are you today?",
            Some(context),
            &sample_terms(),
        );
        assert_eq!(result.text, "Hello world, how are you today?");
        assert!(!result.cleared);
    }

    #[test]
    fn sanitize_strips_verbatim_prefix_echo() {
        let context = "Glossary: Voicey, Cursor, metformin, HbA1c";
        let result = sanitize_steering_echo(
            "Glossary: Voicey, Cursor, metformin, HbA1c the patient took metformin",
            Some(context),
            &sample_terms(),
        );
        assert_eq!(result.text, "the patient took metformin");
        assert!(!result.cleared);
    }

    #[test]
    fn sanitize_clears_exact_echo() {
        let context = "Glossary: Voicey, Cursor, metformin, HbA1c";
        let result = sanitize_steering_echo(context, Some(context), &sample_terms());
        assert_eq!(result.text, "");
        assert!(result.cleared);
    }

    #[test]
    fn sanitize_clears_reordered_soup() {
        let context = "Glossary: Voicey, Cursor, metformin, HbA1c";
        let result =
            sanitize_steering_echo("metformin, Cursor, HbA1c, Voicey", Some(context), &sample_terms());
        assert_eq!(result.text, "");
        assert!(result.cleared);
    }

    #[test]
    fn sanitize_keeps_incidental_term_overlap() {
        let context = "Glossary: Voicey, Cursor, metformin, HbA1c";
        let result = sanitize_steering_echo(
            "I really enjoy using Cursor and Voicey for my daily work",
            Some(context),
            &sample_terms(),
        );
        assert_eq!(
            result.text,
            "I really enjoy using Cursor and Voicey for my daily work"
        );
        assert!(!result.cleared);
    }

    #[test]
    fn sanitize_keeps_short_biased_term_below_minimum() {
        let context = "Glossary: Voicey, Cursor, metformin, HbA1c";
        let result = sanitize_steering_echo("Cursor Voicey", Some(context), &sample_terms());
        assert_eq!(result.text, "Cursor Voicey");
        assert!(!result.cleared);
    }

    #[test]
    fn sanitize_without_context_keeps_text() {
        let result = sanitize_steering_echo("metformin Cursor HbA1c Voicey", None, &[]);
        assert_eq!(result.text, "metformin Cursor HbA1c Voicey");
        assert!(!result.cleared);
    }
}
