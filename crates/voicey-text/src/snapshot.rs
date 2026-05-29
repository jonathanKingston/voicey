//! Text gathered from the accessibility tree for vocabulary steering.

/// Text gathered from the accessibility tree for vocabulary steering (platform-agnostic).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ScreenContextSnapshot {
    /// Focused value, selection, and similar high-signal text used as the BM25 query.
    pub query_text: String,
    /// Shallow AX walk chunks scored against the query.
    pub corpus_chunks: Vec<String>,
}

impl ScreenContextSnapshot {
    pub fn new(query_text: impl Into<String>, corpus_chunks: Vec<String>) -> Self {
        Self {
            query_text: query_text.into(),
            corpus_chunks,
        }
    }

    pub const fn empty() -> Self {
        Self {
            query_text: String::new(),
            corpus_chunks: Vec::new(),
        }
    }
}
