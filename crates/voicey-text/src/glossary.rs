//! Builds decoder context strings for on-device ASR vocabulary biasing.

use crate::screen_term_selector;

/// Upper bound on glossary context length passed to the model.
pub const MAX_CONTEXT_CHARACTER_COUNT: usize = 2000;

/// Always included in steering glossaries when biasing is enabled.
pub const BUILT_IN_TERMS: &[&str] = &["Voicey"];

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

/// Removes decoder steering text when the model echoes it instead of transcribing speech.
pub fn stripping_echoed_decoder_context(text: &str, decoder_context: Option<&str>) -> String {
    let Some(decoder_context) = decoder_context else {
        return text.to_string();
    };
    let normalized_context = decoder_context.trim();
    if normalized_context.is_empty() {
        return text.to_string();
    }

    let mut remainder = text.trim().to_string();
    if remainder.is_empty() {
        return remainder;
    }

    if remainder == normalized_context {
        return String::new();
    }
    if remainder.starts_with(normalized_context) {
        remainder = remainder[normalized_context.len()..].trim().to_string();
        if remainder.starts_with(',') || remainder.starts_with(':') {
            remainder = remainder[1..].trim().to_string();
        }
    }
    remainder
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
}
