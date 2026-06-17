//! Bounded edit-distance repair of tokens against a vocabulary list.

const DEFAULT_MAX_DISTANCE: usize = 1;
const MIN_TOKEN_LENGTH: usize = 4;

/// Replace whole-word tokens when within `max_distance` Levenshtein distance of a vocabulary term.
pub fn repair_vocabulary(text: &str, terms: &[String], max_distance: usize) -> String {
    if terms.is_empty() {
        return text.to_string();
    }

    let canonical: Vec<(String, String)> = terms
        .iter()
        .filter_map(|term| {
            let trimmed = term.trim();
            if trimmed.is_empty() {
                None
            } else {
                Some((normalized_key(trimmed), trimmed.to_string()))
            }
        })
        .collect();

    if canonical.is_empty() {
        return text.to_string();
    }

    let mut output = String::new();
    let mut last_end = 0;
    for (start, end, token) in word_spans(text) {
        if start > last_end {
            output.push_str(&text[last_end..start]);
        }
        if let Some(replacement) = best_replacement(token, &canonical, max_distance) {
            output.push_str(&preserve_token_casing(token, &replacement));
        } else {
            output.push_str(token);
        }
        last_end = end;
    }
    output.push_str(&text[last_end..]);
    output
}

pub fn repair_vocabulary_default(text: &str, terms: &[String]) -> String {
    repair_vocabulary(text, terms, DEFAULT_MAX_DISTANCE)
}

fn best_replacement(
    token: &str,
    canonical: &[(String, String)],
    max_distance: usize,
) -> Option<String> {
    let key = normalized_key(token);
    if key.len() < MIN_TOKEN_LENGTH {
        return None;
    }

    let mut best: Option<(usize, String)> = None;
    for (term_key, term_value) in canonical {
        if key == *term_key {
            return None;
        }
        let distance = levenshtein(&key, term_key);
        if distance == 0 || distance > max_distance {
            continue;
        }
        match &best {
            Some((best_distance, _)) if *best_distance <= distance => {}
            _ => best = Some((distance, term_value.clone())),
        }
    }
    best.map(|(_, value)| value)
}

fn preserve_token_casing(original: &str, replacement: &str) -> String {
    if original.chars().all(|ch| !ch.is_alphabetic() || ch.is_uppercase()) {
        return replacement.to_uppercase();
    }
    if original.chars().next().is_some_and(|ch| ch.is_uppercase()) {
        let mut chars = replacement.chars();
        match chars.next() {
            None => replacement.to_string(),
            Some(first) => first.to_uppercase().collect::<String>() + chars.as_str(),
        }
    } else {
        replacement.to_string()
    }
}

fn normalized_key(text: &str) -> String {
    text.chars()
        .filter(|ch| ch.is_alphanumeric())
        .flat_map(|ch| ch.to_lowercase())
        .collect()
}

fn word_spans(text: &str) -> Vec<(usize, usize, &str)> {
    let mut spans = Vec::new();
    let mut start: Option<usize> = None;
    for (index, ch) in text.char_indices() {
        if ch.is_alphanumeric() {
            if start.is_none() {
                start = Some(index);
            }
        } else if let Some(word_start) = start {
            spans.push((word_start, index, &text[word_start..index]));
            start = None;
        }
    }
    if let Some(word_start) = start {
        spans.push((word_start, text.len(), &text[word_start..]));
    }
    spans
}

fn levenshtein(left: &str, right: &str) -> usize {
    let left_chars: Vec<char> = left.chars().collect();
    let right_chars: Vec<char> = right.chars().collect();
    if left_chars.is_empty() {
        return right_chars.len();
    }
    if right_chars.is_empty() {
        return left_chars.len();
    }

    let mut previous: Vec<usize> = (0..=right_chars.len()).collect();
    for (i, left_char) in left_chars.iter().enumerate() {
        let mut current = vec![i + 1; right_chars.len() + 1];
        for (j, right_char) in right_chars.iter().enumerate() {
            let cost = usize::from(left_char != right_char);
            current[j + 1] = (previous[j + 1] + 1)
                .min(current[j] + 1)
                .min(previous[j] + cost);
        }
        previous = current;
    }
    previous[right_chars.len()]
}

#[cfg(test)]
mod tests {
    use super::*;

  #[test]
  fn repairs_near_match_to_vocabulary_term() {
    let terms = vec!["Kearny".to_string()];
    let repaired = repair_vocabulary_default("Turn on Kearney Street.", &terms);
    assert_eq!(repaired, "Turn on Kearny Street.");
  }

    #[test]
    fn preserves_all_caps_tokens() {
        let terms = vec!["Kearny".to_string()];
        let repaired = repair_vocabulary_default("SOOTER STREET NEAR KEARNEY", &terms);
        assert_eq!(repaired, "SOOTER STREET NEAR KEARNY");
    }

  #[test]
  fn skips_short_tokens() {
    let terms = vec!["Tad".to_string()];
    let repaired = repair_vocabulary_default("Ed agreed.", &terms);
    assert_eq!(repaired, "Ed agreed.");
  }

  #[test]
  fn repairs_three_letter_names_only_when_distance_zero() {
    let terms = vec!["Tad".to_string()];
    let repaired = repair_vocabulary("Ted agreed.", &terms, 1);
    assert_eq!(repaired, "Ted agreed.");
  }

  #[test]
  fn repairs_near_match_for_longer_tokens() {
    let terms = vec!["Kearny".to_string()];
    let repaired = repair_vocabulary_default("Kearney agreed.", &terms);
    assert_eq!(repaired, "Kearny agreed.");
  }

    #[test]
    fn ignores_exact_matches() {
        let terms = vec!["Voicey".to_string()];
        let repaired = repair_vocabulary_default("Voicey works.", &terms);
        assert_eq!(repaired, "Voicey works.");
    }
}
