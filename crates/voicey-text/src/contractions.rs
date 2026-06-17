//! Spoken-form expansions → written contractions for prose dictation.

use regex::Regex;
use std::sync::LazyLock;

struct Rule {
    pattern: &'static str,
    replacement: &'static str,
}

static RULES: &[Rule] = &[
    Rule {
        pattern: r"(?i)\bI am\b",
        replacement: "I'm",
    },
    Rule {
        pattern: r"(?i)\bI will\b",
        replacement: "I'll",
    },
    Rule {
        pattern: r"(?i)\bI have\b",
        replacement: "I've",
    },
    Rule {
        pattern: r"(?i)\bI would\b",
        replacement: "I'd",
    },
    Rule {
        pattern: r"(?i)\bit is\b",
        replacement: "it's",
    },
    Rule {
        pattern: r"(?i)\bthat is\b",
        replacement: "that's",
    },
    Rule {
        pattern: r"(?i)\bthere is\b",
        replacement: "there's",
    },
    Rule {
        pattern: r"(?i)\bwhat is\b",
        replacement: "what's",
    },
    Rule {
        pattern: r"(?i)\bwho is\b",
        replacement: "who's",
    },
    Rule {
        pattern: r"(?i)\bwhere is\b",
        replacement: "where's",
    },
    Rule {
        pattern: r"(?i)\bhow is\b",
        replacement: "how's",
    },
    Rule {
        pattern: r"(?i)\bdo not\b",
        replacement: "don't",
    },
    Rule {
        pattern: r"(?i)\bdoes not\b",
        replacement: "doesn't",
    },
    Rule {
        pattern: r"(?i)\bdid not\b",
        replacement: "didn't",
    },
    Rule {
        pattern: r"(?i)\bcan not\b",
        replacement: "can't",
    },
    Rule {
        pattern: r"(?i)\bcannot\b",
        replacement: "can't",
    },
    Rule {
        pattern: r"(?i)\bcould not\b",
        replacement: "couldn't",
    },
    Rule {
        pattern: r"(?i)\bshould not\b",
        replacement: "shouldn't",
    },
    Rule {
        pattern: r"(?i)\bwould not\b",
        replacement: "wouldn't",
    },
    Rule {
        pattern: r"(?i)\bwill not\b",
        replacement: "won't",
    },
    Rule {
        pattern: r"(?i)\bis not\b",
        replacement: "isn't",
    },
    Rule {
        pattern: r"(?i)\bare not\b",
        replacement: "aren't",
    },
    Rule {
        pattern: r"(?i)\bwas not\b",
        replacement: "wasn't",
    },
    Rule {
        pattern: r"(?i)\bwere not\b",
        replacement: "weren't",
    },
    Rule {
        pattern: r"(?i)\bhave not\b",
        replacement: "haven't",
    },
    Rule {
        pattern: r"(?i)\bhas not\b",
        replacement: "hasn't",
    },
    Rule {
        pattern: r"(?i)\bhad not\b",
        replacement: "hadn't",
    },
    Rule {
        pattern: r"(?i)\byou are\b",
        replacement: "you're",
    },
    Rule {
        pattern: r"(?i)\bwe are\b",
        replacement: "we're",
    },
    Rule {
        pattern: r"(?i)\bthey are\b",
        replacement: "they're",
    },
    Rule {
        pattern: r"(?i)\blet us\b",
        replacement: "let's",
    },
];

static COMPILED: LazyLock<Vec<(Regex, &'static str)>> = LazyLock::new(|| {
    RULES
        .iter()
        .map(|rule| (Regex::new(rule.pattern).expect("contraction regex"), rule.replacement))
        .collect()
});

/// Convert common spoken expansions to written contractions.
pub fn apply_written_contractions(text: &str) -> String {
    let mut result = text.to_string();
    for (pattern, replacement) in COMPILED.iter() {
        result = pattern.replace_all(&result, *replacement).into_owned();
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn contracts_i_am() {
        assert_eq!(
            apply_written_contractions("I am heading out now."),
            "I'm heading out now."
        );
    }

    #[test]
    fn contracts_it_is_and_negation() {
        assert_eq!(
            apply_written_contractions("It is fine and we are not ready."),
            "it's fine and we aren't ready."
        );
    }

    #[test]
    fn leaves_unrelated_phrases() {
        assert_eq!(
            apply_written_contractions("The patient took metformin."),
            "The patient took metformin."
        );
    }
}
