//! Text pipeline for Voicey: glossary, BM25 term selection, OCR healing, and cleanup.

pub mod bm25;
pub mod glossary;
pub mod contractions;
pub mod itn;
pub mod noise_filter;
pub mod postprocess;
pub mod vocabulary_repair;
pub mod screen_term_filter;
pub mod screen_term_healing;
pub mod screen_term_selector;
pub mod snapshot;
pub mod steering;
pub mod text_cleanup;
pub mod voice_command;
pub mod worker;

pub use bm25::{rank_terms, rank_terms_default, RankedTerm};
pub use glossary::{
    decoding_context, decoding_context_enabled, format as format_glossary, format_terms,
    parse_terms, sanitize_steering_echo, stripping_echoed_decoder_context, SanitizeResult,
    BUILT_IN_TERMS, DECODER_CONTEXT_PREFIX, MAX_CONTEXT_CHARACTER_COUNT,
    MINIMUM_OVERLAP_TOKEN_COUNT,
    STEERING_OVERLAP_CLEAR_THRESHOLD,
};
pub use screen_term_filter::{
    appears_with_word_boundaries, is_date_or_time_token, is_noise_chunk, is_steering_noise_token,
    tokenize, MAX_TOKEN_LENGTH, MIN_TOKEN_LENGTH,
};
pub use screen_term_healing::{
    anchor_completion, canonical_term, enriched_tokens, is_interior_fragment,
    merged_adjacent_tokens, MAX_MISSING_PREFIX_LENGTH,
};
pub use screen_term_selector::{
    dedupe_preserving_order, select, select_default, DEFAULT_MAX_SCREEN_TERMS, DEFAULT_MAX_TERMS,
};
pub use snapshot::ScreenContextSnapshot;
pub use steering::{build_steering_context, BuildSteeringContextInput, BuildSteeringContextOutput};
pub use text_cleanup::{
    apply_expansions, capitalize_first, capitalize_i, cleanup_spacing_and_punctuation,
    default_text_expansions, is_conjunction,
};
pub use postprocess::{postprocess, PostProcessInput, TranscriptionSegment};
pub use voice_command::{default_voice_commands, VoiceCommand, VoiceCommandAction};
