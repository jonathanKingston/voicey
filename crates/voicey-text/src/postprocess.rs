//! Post-processes transcription output for punctuation, formatting, and voice commands.

use crate::noise_filter;
use crate::text_cleanup;
use crate::voice_command::{VoiceCommand, VoiceCommandAction};
use regex::Regex;
use std::collections::HashMap;

#[derive(Debug, Clone, PartialEq)]
pub struct TranscriptionSegment {
    pub text: String,
    pub start_time: f64,
    pub end_time: f64,
}

#[derive(Debug, Clone, PartialEq)]
pub struct PostProcessInput {
    pub text: String,
    pub segments: Vec<TranscriptionSegment>,
    pub voice_commands_enabled: bool,
    pub voice_commands: Vec<VoiceCommand>,
}

/// Post-process transcription text using the same pipeline as Swift `PostProcessor`.
pub fn postprocess(input: &PostProcessInput) -> String {
    let text_expansions = text_cleanup::default_text_expansions();
    let mut text = input.text.clone();

    text = noise_filter::filter_noise(&text);

    if text.trim().is_empty() {
        return String::new();
    }

    text = apply_intelligent_punctuation(&text, &input.segments);
    text = apply_text_expansions(&text, &text_expansions);

    if input.voice_commands_enabled {
        let enabled_commands: Vec<_> = input
            .voice_commands
            .iter()
            .filter(|command| command.enabled)
            .cloned()
            .collect();
        text = process_voice_commands(&text, &enabled_commands);
    }

    text_cleanup::cleanup_spacing_and_punctuation(&text)
}

fn apply_text_expansions(text: &str, expansions: &HashMap<&str, &str>) -> String {
    let mut result = text_cleanup::apply_expansions(text, expansions);
    result = text_cleanup::capitalize_i(&result);
    result
}

fn apply_intelligent_punctuation(text: &str, segments: &[TranscriptionSegment]) -> String {
    if segments.is_empty() {
        return text.to_string();
    }

    let processed_segments = analyze_segments(segments);
    let mut result = reconstruct_text(&processed_segments);
    result = text_cleanup::capitalize_first(&result);

    if result
        .chars()
        .last()
        .is_none_or(|last| !".!?".contains(last))
    {
        result.push('.');
    }

    result
}

fn analyze_segments(segments: &[TranscriptionSegment]) -> Vec<(String, String)> {
    let mut previous_end_time = 0.0;
    let mut processed_segments = Vec::with_capacity(segments.len());

    for (index, segment) in segments.iter().enumerate() {
        let pause_before_segment = segment.start_time - previous_end_time;
        let segment_text = segment.text.trim().to_string();
        let punctuation = determine_punctuation(
            pause_before_segment,
            &segment_text,
            segment,
            index == 0,
        );
        processed_segments.push((segment_text, punctuation));
        previous_end_time = segment.end_time;
    }

    processed_segments
}

fn determine_punctuation(
    pause_before_segment: f64,
    segment_text: &str,
    segment: &TranscriptionSegment,
    is_first_segment: bool,
) -> String {
    if is_first_segment {
        return String::new();
    }

    if pause_before_segment > 1.5 {
        "...".to_string()
    } else if pause_before_segment > 0.6 {
        infer_sentence_end_punctuation(segment)
    } else if pause_before_segment > 0.3
        && !segment_text.is_empty()
        && !text_cleanup::is_conjunction(segment_text)
    {
        ",".to_string()
    } else {
        String::new()
    }
}

fn reconstruct_text(processed_segments: &[(String, String)]) -> String {
    let mut result = String::new();

    for (index, segment) in processed_segments.iter().enumerate() {
        if index > 0 && !segment.1.is_empty() {
            result = result.trim_end().to_string();
            result.push_str(&segment.1);
            result.push(' ');
        } else if index > 0 {
            result.push(' ');
        }

        let mut segment_text = segment.0.clone();
        if index > 0 {
            if let Some(last_char) = processed_segments[index - 1].1.chars().last() {
                if ".!?".contains(last_char) {
                    segment_text = text_cleanup::capitalize_first(&segment_text);
                }
            }
        }

        result.push_str(&segment_text);
    }

    result
}

fn infer_sentence_end_punctuation(segment: &TranscriptionSegment) -> String {
    let text = segment.text.to_lowercase();

    let question_starters = [
        "what", "where", "when", "why", "who", "how", "which", "whose", "whom", "is it",
        "are you", "do you", "can you", "will you", "would you", "could you", "should",
        "have you", "has", "does", "did",
    ];

    for starter in question_starters {
        if text.starts_with(starter) || text.contains(&format!(" {starter} ")) {
            return "?".to_string();
        }
    }

    let question_enders = [
        "right",
        "correct",
        "isn't it",
        "aren't you",
        "don't you",
        "won't you",
    ];
    for ender in question_enders {
        if text.ends_with(ender) {
            return "?".to_string();
        }
    }

    ".".to_string()
}

fn process_voice_commands(text: &str, voice_commands: &[VoiceCommand]) -> String {
    let mut result = text.to_string();

    for command in voice_commands {
        let pattern = format!(r"(?i)\b{}\b", regex::escape(&command.phrase));
        let Ok(re) = Regex::new(&pattern) else {
            continue;
        };
        result = apply_voice_command(command, &re, &result);
    }

    result
}

fn apply_voice_command(command: &VoiceCommand, regex: &Regex, text: &str) -> String {
    match &command.action {
        VoiceCommandAction::NewLine => regex.replace_all(text, "\n").into_owned(),
        VoiceCommandAction::NewParagraph => regex.replace_all(text, "\n\n").into_owned(),
        VoiceCommandAction::ScratchThat => apply_scratch_that(command, text),
        VoiceCommandAction::Custom { replacement } => {
            regex.replace_all(text, replacement.as_str()).into_owned()
        }
    }
}

fn apply_scratch_that(command: &VoiceCommand, text: &str) -> String {
    let lower_text = text.to_lowercase();
    let lower_phrase = command.phrase.to_lowercase();
    let Some(start_byte) = lower_text.rfind(&lower_phrase) else {
        return text.to_string();
    };
    let end_byte = start_byte + command.phrase.len();

    let before_command = &text[..start_byte];
    if let Some((sentence_byte, punct)) = before_command
        .char_indices()
        .rfind(|(_, character)| ".!?".contains(*character))
    {
        let after_sentence_byte = sentence_byte + punct.len_utf8();
        format!("{}{}", &text[..after_sentence_byte], &text[end_byte..])
    } else {
        text[end_byte..].to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::voice_command::default_voice_commands;

    fn input(text: &str) -> PostProcessInput {
        PostProcessInput {
            text: text.to_string(),
            segments: Vec::new(),
            voice_commands_enabled: false,
            voice_commands: Vec::new(),
        }
    }

    #[test]
    fn segment_less_output_is_stable() {
        assert_eq!(postprocess(&input("hello world")), "hello world");
    }

    #[test]
    fn empty_after_noise_filter() {
        assert_eq!(postprocess(&input("*music*")), "");
        assert_eq!(postprocess(&input("...")), "");
    }

    #[test]
    fn skips_intelligent_punctuation_without_segments() {
        let result = postprocess(&input("hello world"));
        assert_eq!(result, "hello world");
    }

    #[test]
    fn applies_intelligent_punctuation_with_segments() {
        let mut request = input("hello there");
        request.segments = vec![
            TranscriptionSegment {
                text: "hello".to_string(),
                start_time: 0.0,
                end_time: 0.5,
            },
            TranscriptionSegment {
                text: "there".to_string(),
                start_time: 1.5,
                end_time: 2.0,
            },
        ];
        assert_eq!(postprocess(&request), "Hello. there.");
    }

    #[test]
    fn long_pause_inserts_ellipsis() {
        let mut request = input("one two");
        request.segments = vec![
            TranscriptionSegment {
                text: "one".to_string(),
                start_time: 0.0,
                end_time: 0.5,
            },
            TranscriptionSegment {
                text: "two".to_string(),
                start_time: 2.5,
                end_time: 3.0,
            },
        ];
        // Swift cleanup collapses "..." to "." via repeated ".." replacement.
        assert_eq!(postprocess(&request), "One. two.");
    }

    #[test]
    fn medium_pause_inserts_comma_for_non_conjunction() {
        let mut request = input("hello world");
        request.segments = vec![
            TranscriptionSegment {
                text: "hello".to_string(),
                start_time: 0.0,
                end_time: 0.5,
            },
            TranscriptionSegment {
                text: "world".to_string(),
                start_time: 0.9,
                end_time: 1.2,
            },
        ];
        assert_eq!(postprocess(&request), "Hello, world.");
    }

    #[test]
    fn voice_commands_new_line() {
        let mut request = input("first new line second");
        request.voice_commands_enabled = true;
        request.voice_commands = default_voice_commands();
        assert_eq!(postprocess(&request), "first \n second");
    }

    #[test]
    fn voice_commands_custom_replacement() {
        let mut request = input("for example this works");
        request.voice_commands_enabled = true;
        request.voice_commands = default_voice_commands();
        assert_eq!(postprocess(&request), "e. g. this works");
    }

    #[test]
    fn voice_commands_scratch_that() {
        let mut request = input("keep this. remove me scratch that");
        request.voice_commands_enabled = true;
        request.voice_commands = default_voice_commands();
        assert_eq!(postprocess(&request), "keep this.");
    }

    #[test]
    fn default_expansions_normalize_spelled_out_ok() {
        assert_eq!(postprocess(&input("that sounds o k to me")), "that sounds OK to me");
    }
}
