//! Voice command action types and default phrases (no UUID — settings are supplied by the host).

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "action", rename_all = "snake_case")]
pub enum VoiceCommandAction {
    NewLine,
    NewParagraph,
    ScratchThat,
    Custom { replacement: String },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct VoiceCommand {
    pub phrase: String,
    #[serde(flatten)]
    pub action: VoiceCommandAction,
    pub enabled: bool,
}

impl VoiceCommand {
    pub fn new(phrase: impl Into<String>, action: VoiceCommandAction, enabled: bool) -> Self {
        Self {
            phrase: phrase.into(),
            action,
            enabled,
        }
    }
}

/// Default voice commands matching Swift `VoiceCommand.defaults` (phrase + action only).
pub fn default_voice_commands() -> Vec<VoiceCommand> {
    vec![
        VoiceCommand::new("new line", VoiceCommandAction::NewLine, true),
        VoiceCommand::new("new paragraph", VoiceCommandAction::NewParagraph, true),
        VoiceCommand::new("scratch that", VoiceCommandAction::ScratchThat, true),
        VoiceCommand::new(
            "etcetera",
            VoiceCommandAction::Custom {
                replacement: "etc.".to_string(),
            },
            true,
        ),
        VoiceCommand::new(
            "et cetera",
            VoiceCommandAction::Custom {
                replacement: "etc.".to_string(),
            },
            true,
        ),
        VoiceCommand::new(
            "for example",
            VoiceCommandAction::Custom {
                replacement: "e.g.".to_string(),
            },
            true,
        ),
        VoiceCommand::new(
            "versus",
            VoiceCommandAction::Custom {
                replacement: "vs.".to_string(),
            },
            true,
        ),
        VoiceCommand::new(
            "mister",
            VoiceCommandAction::Custom {
                replacement: "Mr.".to_string(),
            },
            true,
        ),
        VoiceCommand::new(
            "missus",
            VoiceCommandAction::Custom {
                replacement: "Mrs.".to_string(),
            },
            true,
        ),
        VoiceCommand::new(
            "doctor",
            VoiceCommandAction::Custom {
                replacement: "Dr.".to_string(),
            },
            true,
        ),
        VoiceCommand::new(
            "okay",
            VoiceCommandAction::Custom {
                replacement: "OK".to_string(),
            },
            true,
        ),
    ]
}
