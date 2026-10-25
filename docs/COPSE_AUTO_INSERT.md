# Copse auto-insert

## Problem and change

The previous Voicey insertion path accepted successful AX setters/actions as proof of delivery. Its fallback search could return an AXWebArea before finding the focused textbox. Cursor-insertion and append fallbacks rewrote AXValue, risking loss of selection and inline attachment content.

Voicey now dispatches one clipboard Cmd+V to the captured target PID. AX is read only. Focused-input discovery descends through containers and only observes focused text input roles. The destination editor handles the selection, caret, inline content and normal paste/input events.

Delivery distinguishes:

- `notAttempted`: permission, clipboard, activation or event construction prevented dispatch.
- `unconfirmed`: dispatch occurred without an exact observable AX text/caret transition, or focus was lost. Voicey never retries automatically; clipboard restoration follows the user's setting.
- `confirmed`: AX value and caret match the predicted UTF-16 insertion transition. This does not independently prove Copse's renderer draft/send state.

There are no AX setters, whole-field replacements, app-level AXPaste actions or fallback shortcuts after dispatch. Activation failure leaves the transcription on the clipboard. Clipboard transactions are serialized so overlapping dictations cannot overwrite an in-flight paste. Restoration after dispatch requires an unchanged pasteboard change count; it does not require AX confirmation, because some Electron editors accept the paste without exposing an exact text/caret transition. When dispatch is not attempted, Voicey leaves the transcription on the clipboard. A user copy during activation takes precedence over automatic insertion.

Output logs record method, target PID, focused role, dispatch and outcome. A posted event is logged as dispatched, never as successful insertion.

## Validation

The patched direct-distribution app compiled using Xcode 27.1 selected through `DEVELOPER_DIR`. Metal shaders and all four Rust workers built, and the packaged, ad-hoc-signed workspace app was launched and its running bundle path verified.

The user subsequently reported “ok this works” after an Accessibility grant-reset step. This is user-reported confirmation, not an agent-observed recording-to-delivery trace or a scenario-by-scenario result. The session did not establish the old build's failing method, whether manual Cmd+V worked after dictation, or whether the permission reset alone would have resolved the original failure.

Native XCTest validation passed: 71 tests, zero failures, including all 58 app-layer tests and 13 new core paste tests. The new regression coverage comprises seven OutputManager tests and 13 core paste tests. SwiftLint could not run locally because it is not installed; the whitespace check passed. Tests cover focused textbox discovery, bounded traversal, UTF-16 text/caret predictions, unchanged/missing/delayed AX observations, focus loss, single dispatch, activation failure, clipboard restoration on/off, external clipboard changes and overlapping deliveries. OutputManager tests use named macOS pasteboards and an injected delivery boundary; they do not prove real editor insertion.

After dependency resolution, the local validation command for the app-layer tests plus the new core tests was:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH="$PWD/.build/paste-module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/paste-module-cache" \
VOICEY_DIRECT=1 swift test --disable-sandbox --build-system native \
  --disable-automatic-resolution --cache-path "$PWD/.build/spm-cache" \
  -Xswiftc -DVOICEY_DIRECT_DISTRIBUTION --filter 'VoiceyTests|PasteAttemptTests'
```

The local run log is `.build/pr-output-tests.log`. The standard macOS CI workflow runs `make build` and `swift test --filter VoiceyTests`; Linux core CI runs the new PasteAttemptTests through VoiceyCoreTests.

## Remaining real Copse checks

The full matrix below remains unverified by the agent. Desktop automation failed to initialize, and unified log collection was blocked by the command sandbox. No recording or screenshots of a real Voicey-to-Copse dictation flow were captured.

Use a disposable unsent Copse chat and the signed branch app. Record the actual recording/transcription/overlay-dismissal/delivery flow with method/outcome logs.

| Case | Required assertion |
| --- | --- |
| Empty composer | Complete transcription appears exactly once |
| Existing draft | Inserts at caret; prefix/suffix preserved |
| Selected text | Only selection replaced |
| Inline attachment | Chip identity and surrounding draft survive |
| Multiline and emoji | Text/newlines and caret position remain correct |
| Repeated dictations | No missing, stale or duplicate insertions |
| Restore enabled / disabled | Both deliver; original clipboard returns after a dispatched paste when enabled, including an unconfirmed AX observation |
| Overlay focus return | Intended Copse composer receives paste |
| Activation failure | No other app receives paste; clipboard retained |

For every successful case, edit the inserted text, verify Copse's actual draft/send state includes it, and verify that no message was submitted. AX matching alone does not satisfy these assertions.

## Copse changes

No necessary Copse source change has been established. Its source is outside this checkout.

If manual paste updates the DOM without updating the draft, investigate the existing paste/input-to-draft synchronization path and reuse the composer's text-and-chip serialization. Avoid flattening the editor through innerHTML/textContent. If only overlay return fails, investigate focus restoration separately.

A focused Electron regression should exercise the actual composer and draft store: create a draft with an attachment chip, select a middle text range, write multiline/emoji text through Electron's clipboard API, focus the composer, invoke `webContents.paste()`, and wait for its real handlers. Assert serialized draft text, preserved chip ID, caret, send-button state, editability and zero sends; repeat with a new clipboard payload. This is a test specification, not an implemented Copse test.
