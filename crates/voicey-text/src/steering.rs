//! Builds Qwen decoder steering context from manual glossary and screen snapshots.

use crate::glossary;
use crate::screen_term_selector;
use crate::snapshot::ScreenContextSnapshot;

pub struct BuildSteeringContextInput<'a> {
    pub manual_glossary_enabled: bool,
    pub manual_glossary: &'a str,
    pub screen_context_enabled: bool,
    pub snapshot: Option<&'a ScreenContextSnapshot>,
    pub max_terms: usize,
}

pub struct BuildSteeringContextOutput {
    pub terms: Vec<String>,
    pub decoder_context: Option<String>,
}

/// Mirrors Swift `TranscriptionSteeringContext.make` + `ScreenContextStore.consumeScreenTerms`.
pub fn build_steering_context(input: &BuildSteeringContextInput<'_>) -> BuildSteeringContextOutput {
    if !input.manual_glossary_enabled && !input.screen_context_enabled {
        return BuildSteeringContextOutput {
            terms: Vec::new(),
            decoder_context: None,
        };
    }

    let mut manual_terms = Vec::new();
    if input.manual_glossary_enabled {
        manual_terms = glossary::parse_terms(input.manual_glossary);
    }

    let mut screen_terms = Vec::new();
    if input.screen_context_enabled {
        screen_terms = screen_term_selector::select(
            input.snapshot,
            input.manual_glossary,
            false,
            input.max_terms,
        );
    }

    let mut terms = manual_terms;
    terms.extend(screen_terms);
    let decoder_context = glossary::decoding_context(&terms);
    BuildSteeringContextOutput {
        terms,
        decoder_context,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn manual_glossary_only() {
        let output = build_steering_context(&BuildSteeringContextInput {
            manual_glossary_enabled: true,
            manual_glossary: "Cursor, Composer",
            screen_context_enabled: false,
            snapshot: None,
            max_terms: screen_term_selector::DEFAULT_MAX_TERMS,
        });
        assert_eq!(output.terms, vec!["Cursor", "Composer"]);
        assert!(
            output
                .decoder_context
                .as_deref()
                .unwrap_or("")
                .contains("Cursor")
        );
    }

    #[test]
    fn disabled_settings_returns_empty() {
        let output = build_steering_context(&BuildSteeringContextInput {
            manual_glossary_enabled: false,
            manual_glossary: "",
            screen_context_enabled: false,
            snapshot: None,
            max_terms: screen_term_selector::DEFAULT_MAX_TERMS,
        });
        assert!(output.terms.is_empty());
        assert!(output.decoder_context.is_none());
    }
}
