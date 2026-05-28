//! Selects vocabulary terms from accessibility snapshots using BM25 and deduplication.

use crate::bm25;
use crate::glossary;
use crate::screen_term_filter;
use crate::screen_term_healing;
use crate::snapshot::ScreenContextSnapshot;

pub const DEFAULT_MAX_TERMS: usize = 60;

pub fn select(
    snapshot: Option<&ScreenContextSnapshot>,
    manual_glossary: &str,
    manual_glossary_enabled: bool,
    max_terms: usize,
) -> Vec<String> {
    let mut must_keep = Vec::new();
    if manual_glossary_enabled {
        must_keep.extend(glossary::parse_terms(manual_glossary));
    }

    let Some(snapshot) = snapshot else {
        return dedupe_preserving_order(&must_keep, max_terms);
    };

    let query_parts: Vec<&str> = [
        snapshot.query_text.as_str(),
        if manual_glossary_enabled {
            manual_glossary
        } else {
            ""
        },
    ]
    .into_iter()
    .filter(|part| !part.trim().is_empty())
    .collect();
    let query = query_parts.join(" ");

    let chunks: Vec<String> = snapshot
        .corpus_chunks
        .iter()
        .filter(|chunk| !screen_term_filter::is_noise_chunk(chunk))
        .cloned()
        .collect();

    let corpus_anchors: Vec<String> = chunks
        .iter()
        .flat_map(|chunk| screen_term_filter::tokenize(chunk))
        .filter(|token| token.len() >= 5)
        .collect();

    let anchor_source: Vec<String> = glossary::BUILT_IN_TERMS
        .iter()
        .map(|s| (*s).to_string())
        .chain(must_keep.iter().cloned())
        .chain(corpus_anchors)
        .collect();
    let anchors = dedupe_preserving_order(&anchor_source, 200);

    let ranked_terms = bm25::rank_terms_default(&query, &chunks, &anchors);

    let mut selected = must_keep.clone();
    let must_keep_keys: std::collections::HashSet<String> =
        must_keep.iter().map(|term| normalized_key(term)).collect();

    for entry in ranked_terms {
        let term = screen_term_healing::canonical_term(&entry.term, &anchors);
        if screen_term_filter::is_steering_noise_token(&term) {
            continue;
        }
        if screen_term_healing::is_interior_fragment(&term, &anchors) {
            continue;
        }
        let key = normalized_key(&entry.term);
        if must_keep_keys.contains(&key) {
            continue;
        }
        selected.push(term);
        if selected.len() >= max_terms {
            break;
        }
    }

    if selected.len() < max_terms && !query.is_empty() {
        let query_tokens = screen_term_healing::enriched_tokens(&query, &anchors);
        for token in query_tokens {
            if screen_term_filter::is_steering_noise_token(&token) {
                continue;
            }
            if screen_term_healing::is_interior_fragment(&token, &anchors) {
                continue;
            }
            let key = normalized_key(&token);
            if must_keep_keys.contains(&key) {
                continue;
            }
            if !selected
                .iter()
                .any(|existing| normalized_key(existing) == key)
            {
                selected.push(token);
            }
            if selected.len() >= max_terms {
                break;
            }
        }
    }

    dedupe_preserving_order(&selected, max_terms)
}

pub fn select_default(
    snapshot: Option<&ScreenContextSnapshot>,
    manual_glossary: &str,
    manual_glossary_enabled: bool,
) -> Vec<String> {
    select(
        snapshot,
        manual_glossary,
        manual_glossary_enabled,
        DEFAULT_MAX_TERMS,
    )
}

pub fn dedupe_preserving_order(terms: &[String], max_count: usize) -> Vec<String> {
    let mut seen = std::collections::HashSet::new();
    let mut result = Vec::new();
    for term in terms {
        let trimmed = term.trim();
        if trimmed.is_empty() {
            continue;
        }
        let key = normalized_key(trimmed);
        if seen.contains(&key) {
            continue;
        }
        seen.insert(key);
        result.push(trimmed.to_string());
        if result.len() >= max_count {
            break;
        }
    }
    result
}

fn normalized_key(term: &str) -> String {
    term.to_lowercase()
        .chars()
        .filter(|c| c.is_ascii_alphabetic() || c.is_ascii_digit())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::snapshot::ScreenContextSnapshot;

    #[test]
    fn select_keeps_manual_glossary_terms() {
        let snapshot = ScreenContextSnapshot::new(
            "patient metformin",
            vec![
                "toolbar cancel ok".to_string(),
                "HbA1c lab result metformin".to_string(),
            ],
        );

        let terms = select_default(Some(&snapshot), "Voicey", true);
        assert!(terms.iter().any(|t| t == "Voicey"));
    }

    #[test]
    fn select_ranks_snapshot_terms_without_manual_output() {
        let snapshot = ScreenContextSnapshot::new(
            "metformin dosage",
            vec![
                "Patient metformin dosage increased".to_string(),
                "File Edit View Help".to_string(),
            ],
        );

        let terms = select_default(Some(&snapshot), "Voicey", false);
        assert!(terms.iter().any(|t| t.eq_ignore_ascii_case("metformin")));
        assert!(!terms.iter().any(|t| t == "Voicey"));
    }

    #[test]
    fn dedupe_preserves_first_casing() {
        let terms = dedupe_preserving_order(
            &[
                "Voicey".to_string(),
                "voicey".to_string(),
                "VOICEY".to_string(),
                "Qwen".to_string(),
            ],
            10,
        );
        assert_eq!(terms, vec!["Voicey", "Qwen"]);
    }
}
