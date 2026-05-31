//! Okapi BM25 ranking for lightweight on-device term selection.

use crate::screen_term_healing;

#[derive(Debug, Clone, PartialEq)]
pub struct RankedTerm {
    pub term: String,
    pub score: f32,
}

/// Ranks document terms by BM25 relevance to the query.
pub fn rank_terms(
    query: &str,
    documents: &[String],
    anchor_vocabulary: &[String],
    k1: f32,
    length_normalization: f32,
) -> Vec<RankedTerm> {
    let doc_tokens: Vec<Vec<String>> = documents
        .iter()
        .map(|doc| screen_term_healing::enriched_tokens(doc, anchor_vocabulary))
        .collect();
    if doc_tokens.is_empty() {
        return Vec::new();
    }

    let query_tokens = screen_term_healing::enriched_tokens(query, anchor_vocabulary);
    if query_tokens.is_empty() {
        return Vec::new();
    }

    let avg_doc_length =
        doc_tokens.iter().map(|t| t.len()).sum::<usize>() as f32 / doc_tokens.len() as f32;
    let document_frequency = term_document_frequency(&doc_tokens);
    let total_documents = doc_tokens.len();

    let mut candidate_terms = std::collections::HashSet::new();
    for tokens in &doc_tokens {
        for token in tokens {
            candidate_terms.insert(token.clone());
        }
    }

    let mut term_scores: Vec<RankedTerm> = Vec::new();
    for term in candidate_terms {
        let idf = inverse_document_frequency(
            *document_frequency.get(&term.to_lowercase()).unwrap_or(&0),
            total_documents,
        );
        let mut score = 0.0_f32;
        for tokens in &doc_tokens {
            let term_frequency = tokens
                .iter()
                .filter(|t| t.eq_ignore_ascii_case(&term))
                .count() as f32;
            if term_frequency <= 0.0 {
                continue;
            }
            let doc_length = tokens.len() as f32;
            let numerator = term_frequency * (k1 + 1.0);
            let denominator = term_frequency
                + k1 * (1.0 - length_normalization
                    + length_normalization * (doc_length / avg_doc_length.max(1.0)));
            score += idf * (numerator / denominator);
        }
        if score > 0.0 {
            term_scores.push(RankedTerm { term, score });
        }
    }

    term_scores.sort_by(|a, b| {
        b.score
            .partial_cmp(&a.score)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| a.term.to_lowercase().cmp(&b.term.to_lowercase()))
    });
    term_scores
}

pub fn rank_terms_default(
    query: &str,
    documents: &[String],
    anchor_vocabulary: &[String],
) -> Vec<RankedTerm> {
    rank_terms(query, documents, anchor_vocabulary, 1.2, 0.75)
}

fn term_document_frequency(doc_tokens: &[Vec<String>]) -> std::collections::HashMap<String, usize> {
    let mut frequency = std::collections::HashMap::new();
    for tokens in doc_tokens {
        let unique: std::collections::HashSet<String> =
            tokens.iter().map(|t| t.to_lowercase()).collect();
        for term in unique {
            *frequency.entry(term).or_insert(0) += 1;
        }
    }
    frequency
}

fn inverse_document_frequency(document_frequency: usize, total_documents: usize) -> f32 {
    let doc_freq = document_frequency as f32;
    let total = total_documents as f32;
    ((total - doc_freq + 0.5) / (doc_freq + 0.5) + 1.0).ln()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rank_terms_prefers_relevant_document() {
        let ranked = rank_terms_default(
            "metformin dosage patient",
            &[
                "Patient chart metformin dosage adjustment".to_string(),
                "File Edit View Help Window".to_string(),
                "Unrelated toolbar labels cancel ok".to_string(),
            ],
            &[],
        );

        let top_terms: Vec<String> = ranked
            .iter()
            .take(5)
            .map(|r| r.term.to_lowercase())
            .collect();
        assert!(ranked
            .iter()
            .any(|r| r.term.eq_ignore_ascii_case("metformin")));
        assert!(!top_terms.iter().any(|t| t == "cancel"));
    }
}
