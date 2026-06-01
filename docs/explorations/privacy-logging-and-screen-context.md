# Privacy Logging and Screen Context Defaults

## Status

Exploratory proposal.

## Summary

Voicey is a local transcription app, so transcription text, clipboard contents, and screen
context should be treated as sensitive by default. Some paths currently log raw transcription
text or enable screen-context collection without a dedicated opt-in moment.

## Evidence

- `AppDelegate.handleTranscriptionResult(_:)` logs raw and processed transcription text.
- `OutputManager.deliver(text:targetPID:completion:)` logs full delivered text at debug level.
- `Settings.registerDefaults()` enables `transcriptionScreenContextEnabled` by default.
- `ScreenContextCollector` can read focused values, selected text, and application/window text
  through Accessibility.
- Some steering logs already use `.private`, which shows a privacy-preserving pattern to extend.

Relevant files:

- `Sources/Voicey/App/AppDelegate.swift`
- `Sources/Voicey/Output/OutputManager.swift`
- `Sources/Voicey/Transcription/PostProcessor.swift`
- `Sources/Voicey/Utilities/Settings.swift`
- `Sources/Voicey/Accessibility/ScreenContextCollector.swift`
- `Sources/Voicey/UI/SettingsView.swift`

## Risks

- Sensitive dictated text can appear in unified logs, Console, or diagnostic exports.
- Screen-context collection can surprise users because Accessibility permission is broad.
- Debug logging may expose private content even when the app is otherwise local-only.
- Privacy behavior is inconsistent across logging categories.

## Proposed direction

Adopt a privacy-first logging policy and require clear user consent for screen context. Keep
operational metrics useful by logging counts, lengths, state transitions, and redacted previews
instead of content.

Possible implementation shape:

1. Replace raw transcription logs with lengths or `.private` interpolation.
2. Gate any content previews behind `enableDetailedLogging`.
3. Change screen context to opt-in, or add onboarding that requires an explicit choice.
4. Update Settings copy to explain what is read, when it is read, and that it remains on-device.
5. Add a short privacy note to docs or Advanced settings.

## Acceptance criteria

- Raw transcription and clipboard text do not appear in default Console output.
- Sensitive content logs use `.private` and detailed logging gates where needed.
- Screen context is explicitly opted into before first use, or defaults to disabled.
- Settings explain Accessibility text collection in plain language.
- Tests or review checklist cover new sensitive logging calls.

## Validation plan

- Run targeted code review for `AppLogger.*` calls that interpolate user text.
- On macOS, capture logs during transcription and confirm default logs show metadata only.
- Verify onboarding or Settings copy makes screen-context collection explicit before use.
