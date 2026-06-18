//! Builds decoder context strings for on-device ASR vocabulary biasing.

use crate::screen_term_filter;
use crate::screen_term_selector;
use crate::text_cleanup;
use regex::Regex;
use std::collections::HashSet;
use std::sync::LazyLock;

static WORD_SPAN_PATTERN: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"[A-Za-z0-9][A-Za-z0-9\-_'/]*[A-Za-z0-9]|[A-Za-z0-9]").unwrap());
static REPEATED_PERIOD_GAP: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\.\s+\.").unwrap());
static COMMA_BEFORE_PERIOD: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r",\s*\.\s*").unwrap());
static LEADING_ORPHAN_PUNCT: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^[\s.,;:]+").unwrap());

/// Minimum comma-separated segments before list-shaped regurgitation filter applies.
const MIN_COMMA_SEGMENTS_FOR_LIST_FILTER: usize = 8;

/// Fraction of comma segments that must be steering-only to strip the list shape.
const COMMA_STEERING_SEGMENT_FRACTION: f64 = 0.75;

/// Minimum tokens in an embedded vocabulary/glossary run before it is removed.
const MIN_EMBEDDED_STEERING_RUN_TOKEN_COUNT: usize = 4;

/// Consecutive non-steering tokens that end an embedded steering run.
const EMBEDDED_RUN_END_NON_STEERING_TOKEN_COUNT: usize = 2;

/// Upper bound on glossary context length passed to the model.
pub const MAX_CONTEXT_CHARACTER_COUNT: usize = 256;

/// Always included in steering glossaries when biasing is enabled.
pub const BUILT_IN_TERMS: &[&str] = &["Voicey"];

/// Prefix for Qwen3-ASR decoder `context` / system-slot biasing (see TypeWhisper #321).
pub const DECODER_CONTEXT_PREFIX: &str = "Vocabulary: ";

/// Legacy prefix still stripped when the model echoes old-style steering.
const LEGACY_DECODER_CONTEXT_PREFIX: &str = "Glossary: ";

/// Minimum content tokens before the steering-overlap guard may clear output. Below
/// this, short legitimate dictation of a biased term the user actually said is kept.
pub const MINIMUM_OVERLAP_TOKEN_COUNT: usize = 3;

/// Fraction of content tokens that must be steering vocabulary for output to be treated
/// as regurgitated steering "soup" and cleared.
pub const STEERING_OVERLAP_CLEAR_THRESHOLD: f64 = 0.8;

/// Relaxed soup threshold for long comma-shaped screen dumps (many segments, mixed AX tokens).
pub const STEERING_OVERLAP_RELAXED_THRESHOLD: f64 = 0.62;

/// Minimum tokens before relaxed soup threshold applies.
pub const STEERING_OVERLAP_RELAXED_MIN_TOKENS: usize = 12;

/// Returns decoder context for the combined term list, or `None` when empty.
pub fn decoding_context(terms: &[String]) -> Option<String> {
    decoding_context_with_limits(
        terms,
        screen_term_selector::DEFAULT_MAX_TERMS,
        MAX_CONTEXT_CHARACTER_COUNT,
    )
}

/// Like [`decoding_context`] with explicit caps (benchmark harness / IPC overrides only).
pub fn decoding_context_with_limits(
    terms: &[String],
    max_terms: usize,
    max_context_character_count: usize,
) -> Option<String> {
    let merged: Vec<String> = BUILT_IN_TERMS
        .iter()
        .map(|s| (*s).to_string())
        .chain(terms.iter().cloned())
        .collect();
    let unique = screen_term_selector::dedupe_preserving_order(&merged, max_terms);
    if unique.is_empty() {
        return None;
    }
    Some(format_terms_with_limit(
        &unique,
        max_context_character_count,
    ))
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
    format_terms_with_limit(terms, MAX_CONTEXT_CHARACTER_COUNT)
}

/// Formats terms into decoder context with an explicit character cap.
pub fn format_terms_with_limit(terms: &[String], max_context_character_count: usize) -> String {
    if terms.is_empty() {
        return String::new();
    }

    let joined = terms.join(", ");
    let body = format!("{DECODER_CONTEXT_PREFIX}{joined}");
    if body.len() <= max_context_character_count {
        return body;
    }
    body.chars()
        .take(max_context_character_count)
        .collect()
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
/// Prefix/exact echo strip, exact `decoder_context` substrings, comma-list regurgitation,
/// embedded vocabulary-label runs, then whole-utterance steering soup.
pub fn sanitize_steering_echo(
    text: &str,
    decoder_context: Option<&str>,
    steering_terms: &[String],
) -> SanitizeResult {
    let had_input = !text.trim().is_empty();

    let mut stripped = stripping_echoed_decoder_context(text, decoder_context);
    stripped = remove_exact_decoder_context_substrings(&stripped, decoder_context);
    stripped = filter_comma_separated_steering_segments(
        &stripped,
        decoder_context,
        steering_terms,
    );
    stripped = strip_embedded_glossary_runs(&stripped, decoder_context, steering_terms);
    stripped = strip_steering_word_affixes(&stripped, decoder_context, steering_terms);
    stripped = polish_after_steering_strip(&stripped);

    let remainder = stripped.trim();
    if remainder.is_empty() {
        return SanitizeResult {
            text: String::new(),
            cleared: had_input,
        };
    }

    if is_steering_soup(
        remainder,
        decoder_context,
        steering_terms,
        STEERING_OVERLAP_CLEAR_THRESHOLD,
    ) || is_steering_soup(
        remainder,
        decoder_context,
        steering_terms,
        STEERING_OVERLAP_RELAXED_THRESHOLD,
    ) && token_count(remainder) >= STEERING_OVERLAP_RELAXED_MIN_TOKENS
    {
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

/// Removes leading/trailing steering terms echoed after real speech (e.g. `Beep. Hello. Voicey`).
fn strip_steering_word_affixes(
    text: &str,
    decoder_context: Option<&str>,
    steering_terms: &[String],
) -> String {
    let steering = steering_token_set(decoder_context, steering_terms);
    if steering.is_empty() {
        return text.to_string();
    }

    let mut phrases: Vec<String> = BUILT_IN_TERMS
        .iter()
        .map(|t| (*t).to_string())
        .chain(steering_terms.iter().cloned())
        .collect();
    phrases.sort_by_key(|p| std::cmp::Reverse(p.len()));

    let mut out = text.to_string();
    const AFFIX_SEPARATORS: &[&str] = &[". ", ", ", "; ", ": ", " "];
    const MAX_AFFIX_PASSES: usize = 8;

    for _ in 0..MAX_AFFIX_PASSES {
        let mut changed = false;
        out = out.trim().to_string();
        let lower = out.to_ascii_lowercase();

        for phrase in &phrases {
            let phrase_lower = phrase.to_lowercase();
            if phrase_lower.is_empty() {
                continue;
            }
            for sep in AFFIX_SEPARATORS {
                let suffix = format!("{sep}{phrase_lower}");
                if lower.ends_with(&suffix)
                    && trailing_echo_allowed_before_suffix(&out, sep.len() + phrase.len(), &steering)
                {
                    let trim_len = sep.len() + phrase.len();
                    out = out[..out.len().saturating_sub(trim_len)].trim_end().to_string();
                    changed = true;
                    break;
                }
                let prefix = format!("{phrase_lower}{sep}");
                if lower.starts_with(&prefix)
                    && leading_echo_allowed_after_prefix(&out, phrase.len() + sep.len(), &steering)
                {
                    let trim_len = phrase.len() + sep.len();
                    out = out[trim_len..].trim_start().to_string();
                    changed = true;
                    break;
                }
            }
            if changed {
                break;
            }
        }
        if !changed {
            break;
        }
    }

    out
}

/// Trailing steering echo (e.g. `Hello. Voicey`) — require punctuation before the affix.
fn trailing_echo_allowed_before_suffix(
    text: &str,
    suffix_byte_len: usize,
    steering: &HashSet<String>,
) -> bool {
    let body = text[..text.len().saturating_sub(suffix_byte_len)].trim_end();
    if body.is_empty() {
        return false;
    }
    let ends_sentence = body.ends_with('.') || body.ends_with('!') || body.ends_with('?');
    if !ends_sentence {
        return false;
    }
    non_steering_token_count(body, steering) > 0
}

/// Leading steering echo (e.g. `Voicey Cursor the patient ...`) — only peel a leading term
/// when the token immediately after it is ALSO steering. This marks a run of regurgitated
/// terms rather than ordinary dictation that merely starts with a biased common word
/// ("Plan the next sprint" must keep its "Plan"). Mirrors the sentence-boundary guard the
/// trailing branch uses to avoid eating real speech.
fn leading_echo_allowed_after_prefix(
    text: &str,
    prefix_byte_len: usize,
    steering: &HashSet<String>,
) -> bool {
    let body = text[prefix_byte_len.min(text.len())..].trim();
    if body.is_empty() {
        return false;
    }
    // Don't strip if nothing non-steering would remain (pure soup is handled by the
    // overlap guard, not here).
    if non_steering_token_count(body, steering) == 0 {
        return false;
    }
    // The next token must itself be steering for this to be an echoed run.
    screen_term_filter::tokenize(body)
        .first()
        .map(|first| is_steering_token(&first.to_lowercase(), steering))
        .unwrap_or(false)
}

fn non_steering_token_count(text: &str, steering: &HashSet<String>) -> usize {
    screen_term_filter::tokenize(text)
        .into_iter()
        .filter(|token| !is_steering_token(&token.to_lowercase(), steering))
        .count()
}

fn remove_exact_decoder_context_substrings(text: &str, decoder_context: Option<&str>) -> String {
    let Some(context) = decoder_context.map(str::trim).filter(|s| !s.is_empty()) else {
        return text.to_string();
    };
    let mut out = text.to_string();
    loop {
        let Some(pos) = out.find(context) else {
            break;
        };
        out.replace_range(pos..pos + context.len(), " ");
    }
    out
}

/// Screen-term dumps are often comma-separated without the full `decoder_context` string.
fn filter_comma_separated_steering_segments(
    text: &str,
    decoder_context: Option<&str>,
    steering_terms: &[String],
) -> String {
    let steering = steering_token_set(decoder_context, steering_terms);
    if steering.is_empty() {
        return text.to_string();
    }

    let segments: Vec<&str> = text.split(',').map(str::trim).filter(|s| !s.is_empty()).collect();
    if segments.len() < MIN_COMMA_SEGMENTS_FOR_LIST_FILTER {
        return text.to_string();
    }

    let steering_only_count = segments
        .iter()
        .filter(|segment| segment_is_steering_only(segment, &steering, steering_terms))
        .count();
    let ratio = steering_only_count as f64 / segments.len() as f64;
    if ratio < COMMA_STEERING_SEGMENT_FRACTION {
        return text.to_string();
    }

    let kept: Vec<&str> = segments
        .into_iter()
        .filter(|segment| !segment_is_steering_only(segment, &steering, steering_terms))
        .collect();
    kept.join(", ")
}

fn segment_is_steering_only(
    segment: &str,
    steering: &HashSet<String>,
    steering_terms: &[String],
) -> bool {
    let lower = segment.to_lowercase();
    if steering_terms
        .iter()
        .any(|term| term.to_lowercase() == lower)
    {
        return true;
    }
    let tokens: Vec<String> = screen_term_filter::tokenize(segment)
        .into_iter()
        .map(|t| t.to_lowercase())
        .collect();
    if tokens.is_empty() {
        return false;
    }
    tokens.iter().all(|token| is_steering_token(token, steering))
}

fn strip_embedded_glossary_runs(
    text: &str,
    decoder_context: Option<&str>,
    steering_terms: &[String],
) -> String {
    let Some(decoder_context) = decoder_context.map(str::trim).filter(|s| !s.is_empty()) else {
        return text.to_string();
    };
    let steering_tokens = steering_token_set(Some(decoder_context), steering_terms);
    if steering_tokens.is_empty() {
        return text.to_string();
    }

    let mut out = text.to_string();
    loop {
        let lower = out.to_ascii_lowercase();
        let Some((anchor, label_len)) = find_embedded_steering_label(&lower) else {
            break;
        };
        let Some(run_end) =
            embedded_steering_run_end_byte_index(&out[anchor..], &steering_tokens)
        else {
            let skip = anchor + label_len;
            if skip >= out.len() {
                break;
            }
            out.replace_range(anchor..skip, " ");
            continue;
        };
        let mut after = out.split_off(anchor);
        after = after[run_end..].trim_start().to_string();
        let before = trim_join_boundary_tail(out.trim_end());
        let after = trim_join_boundary_head(after.trim_start());
        out = match (before.is_empty(), after.is_empty()) {
            (true, true) => String::new(),
            (true, false) => after,
            (false, true) => before,
            (false, false) => format!("{before} {after}"),
        };
    }
    out
}

fn embedded_steering_run_end_byte_index(
    suffix: &str,
    steering_tokens: &HashSet<String>,
) -> Option<usize> {
    let spans: Vec<(usize, usize, String)> = WORD_SPAN_PATTERN
        .find_iter(suffix)
        .map(|m| (m.start(), m.end(), m.as_str().to_string()))
        .collect();
    if spans.len() < MIN_EMBEDDED_STEERING_RUN_TOKEN_COUNT {
        return None;
    }

    let mut steering_run_tokens = 0;
    let mut non_steering_streak = 0;
    let mut cut_at = 0usize;

    for (start, end, word) in spans {
        let lower = word.to_lowercase();
        if is_steering_token(&lower, steering_tokens) {
            steering_run_tokens += 1;
            non_steering_streak = 0;
            cut_at = end;
        } else {
            non_steering_streak += 1;
            if non_steering_streak >= EMBEDDED_RUN_END_NON_STEERING_TOKEN_COUNT {
                cut_at = start;
                break;
            }
            cut_at = end;
        }
    }

    if steering_run_tokens < MIN_EMBEDDED_STEERING_RUN_TOKEN_COUNT {
        return None;
    }
    Some(cut_at)
}

fn find_embedded_steering_label(lower: &str) -> Option<(usize, usize)> {
    let vocab = lower
        .find("vocabulary:")
        .map(|i| (i, DECODER_CONTEXT_PREFIX.len()));
    let gloss = lower
        .find("glossary:")
        .map(|i| (i, LEGACY_DECODER_CONTEXT_PREFIX.len()));
    match (vocab, gloss) {
        (Some(v), Some(g)) => Some(if v.0 <= g.0 { v } else { g }),
        (Some(v), None) => Some(v),
        (None, Some(g)) => Some(g),
        (None, None) => None,
    }
}

fn is_steering_token(lower: &str, steering: &HashSet<String>) -> bool {
    lower == "glossary"
        || lower == "vocabulary"
        || steering.contains(lower)
}

/// True when the utterance includes at least one word that is not steering vocabulary.
/// Soup detection uses [`screen_term_filter::tokenize`], which drops stopwords and UI
/// chrome, so short filename dictation ("This file is FooBar dot swift") can look like
/// pure steering overlap; raw word spans rescue that case without weakening comma-list
/// or verbatim steering dumps (no ordinary words).
fn has_non_steering_speech_anchor(text: &str, steering: &HashSet<String>) -> bool {
    WORD_SPAN_PATTERN.find_iter(text).any(|m| {
        let word = m.as_str();
        if word.len() < screen_term_filter::MIN_TOKEN_LENGTH
            || word.len() > screen_term_filter::MAX_TOKEN_LENGTH
        {
            return false;
        }
        !is_steering_token(&word.to_lowercase(), steering)
    })
}

fn trim_join_boundary_tail(text: &str) -> String {
    let mut t = text.trim_end().to_string();
    while t.ends_with(',') || t.ends_with(';') || t.ends_with(':') {
        t.pop();
        t = t.trim_end().to_string();
    }
    t
}

fn trim_join_boundary_head(text: &str) -> String {
    let mut t = text.trim_start().to_string();
    while t.starts_with(',') || t.starts_with('.') || t.starts_with(';') || t.starts_with(':') {
        t.remove(0);
        t = t.trim_start().to_string();
    }
    t
}

fn polish_after_steering_strip(text: &str) -> String {
    let mut result = text_cleanup::cleanup_spacing_and_punctuation(text);
    loop {
        let next = REPEATED_PERIOD_GAP.replace_all(&result, ".").into_owned();
        if next == result {
            break;
        }
        result = next;
    }
    result = COMMA_BEFORE_PERIOD.replace_all(&result, ". ").into_owned();
    result = LEADING_ORPHAN_PUNCT.replace_all(&result, "").into_owned();
    trim_trailing_join_artifacts(result)
}

fn trim_trailing_join_artifacts(mut result: String) -> String {
    result = result.trim_end().to_string();
    while result.ends_with(" .") {
        result.truncate(result.len().saturating_sub(2));
        result = result.trim_end().to_string();
    }
    while result.ends_with(',') {
        result.pop();
        result = result.trim_end().to_string();
    }
    while result.ends_with("..") {
        result.pop();
        result = result.trim_end().to_string();
    }
    result
}

/// True when `text` is composed almost entirely of steering vocabulary, indicating the
/// model echoed the glossary/screen terms rather than transcribing speech.
fn token_count(text: &str) -> usize {
    screen_term_filter::tokenize(text).len()
}

fn is_steering_soup(
    text: &str,
    decoder_context: Option<&str>,
    steering_terms: &[String],
    threshold: f64,
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

    if has_non_steering_speech_anchor(text, &steering_tokens) {
        return false;
    }

    let matches = tokens
        .iter()
        .filter(|token| steering_tokens.contains(*token))
        .count();
    let ratio = matches as f64 / tokens.len() as f64;
    ratio >= threshold
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
            Some("Vocabulary: Voicey".to_string())
        );
    }

    #[test]
    fn decoding_context_always_includes_built_in_voicey() {
        assert_eq!(
            decoding_context(&["Metformin".to_string()]),
            Some("Vocabulary: Voicey, Metformin".to_string())
        );
    }

    #[test]
    fn decoding_context_merges_manual_and_screen_terms() {
        let context = decoding_context(&[
            "Voicey".to_string(),
            "metformin".to_string(),
            "Voicey".to_string(),
        ]);
        assert_eq!(context, Some("Vocabulary: Voicey, metformin".to_string()));
    }

    #[test]
    fn format_comma_separated_terms() {
        assert_eq!(
            format("Metformin, HbA1c, nephropathy"),
            "Vocabulary: Metformin, HbA1c, nephropathy"
        );
    }

    #[test]
    fn format_newline_separated_terms() {
        assert_eq!(
            format("QuirkQuid\nP3-Quattro\nO3-Omni"),
            "Vocabulary: QuirkQuid, P3-Quattro, O3-Omni"
        );
    }

    #[test]
    fn format_truncates_long_glossary() {
        let long_term = "a".repeat(MAX_CONTEXT_CHARACTER_COUNT);
        let formatted = format(&long_term);
        assert_eq!(formatted.len(), MAX_CONTEXT_CHARACTER_COUNT);
        assert!(formatted.starts_with("Vocabulary: "));
    }

    #[test]
    fn strip_echoed_decoder_context_exact_match() {
        let context = "Vocabulary: Voicey";
        assert_eq!(
            stripping_echoed_decoder_context("Vocabulary: Voicey", Some(context)),
            ""
        );
    }

    #[test]
    fn strip_echoed_decoder_context_keeps_speech() {
        let context = "Vocabulary: Voicey";
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
    fn sanitize_strips_trailing_built_in_voicey_after_sentence() {
        let context = "Vocabulary: Voicey";
        let result = sanitize_steering_echo("Beep. Hello. Voicey", Some(context), &[]);
        assert_eq!(result.text, "Beep. Hello.");
        assert!(!result.cleared);
    }

    #[test]
    fn sanitize_keeps_intentional_voicey_mention_without_sentence_break() {
        let context = "Vocabulary: Voicey, Cursor";
        let result = sanitize_steering_echo(
            "I love Voicey",
            Some(context),
            &["Cursor".to_string()],
        );
        assert_eq!(result.text, "I love Voicey");
        assert!(!result.cleared);
    }

    #[test]
    fn sanitize_keeps_normal_dictation() {
        let context = "Vocabulary: Voicey, Cursor, metformin, HbA1c";
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
        let context = "Vocabulary: Voicey, Cursor, metformin, HbA1c";
        let result = sanitize_steering_echo(
            "Vocabulary: Voicey, Cursor, metformin, HbA1c the patient took metformin",
            Some(context),
            &sample_terms(),
        );
        assert_eq!(result.text, "the patient took metformin");
        assert!(!result.cleared);
    }

    #[test]
    fn sanitize_clears_exact_echo() {
        let context = "Vocabulary: Voicey, Cursor, metformin, HbA1c";
        let result = sanitize_steering_echo(context, Some(context), &sample_terms());
        assert_eq!(result.text, "");
        assert!(result.cleared);
    }

    #[test]
    fn sanitize_clears_comma_separated_screen_term_list() {
        let context = "Vocabulary: Voicey, Cursor, Composer, Plan, Branch, See, remote";
        let terms = vec![
            "Cursor".to_string(),
            "Composer".to_string(),
            "Plan".to_string(),
            "SanitizeResult".to_string(),
            "Branch".to_string(),
            "See".to_string(),
            "remote".to_string(),
            "tests".to_string(),
            "Create".to_string(),
            "merge".to_string(),
            "validation".to_string(),
        ];
        let input = "Voicey, Cursor, Composer, Plan, SanitizeResult, Branch, See, remote, tests, Create, merge, validation";
        let result = sanitize_steering_echo(input, Some(context), &terms);
        assert_eq!(result.text, "");
        assert!(result.cleared);
    }

    #[test]
    fn sanitize_clears_reordered_soup() {
        let context = "Vocabulary: Voicey, Cursor, metformin, HbA1c";
        let result = sanitize_steering_echo(
            "metformin, Cursor, HbA1c, Voicey",
            Some(context),
            &sample_terms(),
        );
        assert_eq!(result.text, "");
        assert!(result.cleared);
    }

    #[test]
    fn sanitize_keeps_incidental_term_overlap() {
        let context = "Vocabulary: Voicey, Cursor, metformin, HbA1c";
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
        let context = "Vocabulary: Voicey, Cursor, metformin, HbA1c";
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

    fn readaloud_clip5_terms() -> Vec<String> {
        vec![
            "IncrementalTranscriptionCoordinator.swift".to_string(),
            "Voicey".to_string(),
            "Qwen".to_string(),
            "voicey-text".to_string(),
            "UtteranceTranscriptionFinish.swift".to_string(),
            "Klorp-9-alpha".to_string(),
            "ZorbnaxWorker".to_string(),
            "xyzzy-protocol".to_string(),
            "metformin".to_string(),
            "HbA1c".to_string(),
            "coordinator".to_string(),
            "Incremental".to_string(),
            "dot".to_string(),
            "Transcription".to_string(),
            "Agents".to_string(),
        ]
    }

    #[test]
    fn sanitize_readaloud_clip5_filename_sentence_not_cleared() {
        let terms = readaloud_clip5_terms();
        let context = decoding_context(&terms).expect("context");
        let input = "This file is IncrementalTranscriptionCoordinator dot Swift.";
        let result = sanitize_steering_echo(&input, Some(context.as_str()), &terms);
        assert!(
            !result.text.trim().is_empty(),
            "expected deliverable text, got cleared={} text={:?}",
            result.cleared,
            result.text
        );
        assert!(!result.cleared);
    }

    #[test]
    fn sanitize_keeps_leading_common_word_steering_term_in_real_speech() {
        // "Plan" is a screen-context steering term (e.g. an IDE button label) but is also a
        // common English word the user may legitimately start a sentence with. The leading
        // affix strip must NOT eat it when the rest is ordinary dictation.
        let context = "Vocabulary: Voicey, Cursor, Plan, Branch, Create";
        let terms = vec![
            "Cursor".to_string(),
            "Plan".to_string(),
            "Branch".to_string(),
            "Create".to_string(),
        ];
        let result = sanitize_steering_echo(
            "Plan the next sprint with the team tomorrow",
            Some(context),
            &terms,
        );
        assert_eq!(result.text, "Plan the next sprint with the team tomorrow");
        assert!(!result.cleared);
    }
}
