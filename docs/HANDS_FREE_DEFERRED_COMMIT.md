# Hands-Free deferred commit + live transcript

Tech design for fixing fragmented dictation in Hands-Free mode by holding the
paste until the user finishes (or commits), and previewing the accumulated text
in the floating overlay.

## Status

Implemented. This revisits two items the original Hands-Free spec deferred
(["live transcript view" and "live transcript streaming"](HANDS_FREE_RECORDING_MODE.md))
because real-world usage shows the per-utterance paste model produces unnatural
text after natural pauses.

### What shipped

- Hands-Free no longer pastes each utterance. Utterances are transcribed in the
  background and **accumulated** into a session buffer
  (`AppState.pendingHandsFreeUtterances`, keyed by spoken-order sequence).
- The accumulated transcript is shown **live** in the floating overlay as a
  read-only, scrollable region (`TranscriptionOverlayView.transcriptPreview`).
- The buffer is pasted **once** on commit:
  - **Hotkey** while a session is active (`commitHandsFreeSession`), or
  - an **optional, much longer silence timeout** that auto-commits
    (`handsFreeAutoCommitEnabled` setting, `autoCommitSilenceDuration` = 6s,
    well above the 1.5s utterance hangover).
- **Escape / overlay cancel discards** the buffer without pasting
  (`discardHandsFreeSession`) — a deliberate change from the previous
  paste-final-utterance-on-escape behavior.
- A session token drops stale, in-flight utterance transcriptions when a session
  is discarded, and the commit waits for all in-flight transcriptions to drain
  before pasting so nothing is lost or reordered.

### Known limitation

Each utterance is still transcribed independently, so a segment-less model (Qwen)
capitalizes/punctuates each utterance on its own. Joining (`TextCleanup
.joinHandsFreeUtterances`) only handles spacing; it does not re-flow sentence
boundaries across utterances. The structural wins delivered here are: no
premature sentence-cutting on long pauses, a single paste, live visibility, and
user-controlled commit. Cross-utterance re-punctuation (e.g. re-transcribing the
combined audio at commit) is left as a follow-up.

## Problem

In Hands-Free mode, longer-than-hangover pauses chop a single spoken sentence
into multiple independent utterances. Each utterance is transcribed,
post-processed, and pasted on its own, so the output reads as a series of broken
fragments:

> "Hello, my name. Is. Jonathan. And. I'd..."

The user pauses mid-sentence to think, and every pause becomes a sentence
boundary in the output.

This cannot be fixed by elongating the silence timeout:

- A longer hangover delays *every* commit, including genuine sentence ends, which
  makes the whole mode feel sluggish.
- No fixed timeout can distinguish "thinking pause" from "done speaking" — that
  intent only becomes knowable from what the user says next (or from an explicit
  finish gesture).

## Root cause

Each silence-bounded utterance is a fully independent, terminal transcription job
that is delivered immediately.

- `finishHandsFreeUtteranceAndContinueListening()` slices the speech-bounded PCM
  on every silence hangover and calls
  `processTranscription(..., continueHandsFreeSession: true)`
  (`Sources/Voicey/App/AppDelegate.swift`).
- `processTranscription()` post-processes that clip in isolation and calls
  `outputManager?.deliver()` right away
  (`Sources/Voicey/App/AppDelegate.swift`).
- `PostProcessor` (intelligent punctuation/capitalization) only sees one
  utterance's Whisper segments. It has no idea the clip is a sentence
  continuation, so it capitalizes the first word and appends terminal
  punctuation every time.
- The only cross-utterance handling today is a trailing space
  (`handsFreeSeparateNextPasteWithSpace` →
  `TextCleanup.appendingInterUtteranceSpacingIfNeeded`,
  `Sources/VoiceyCore/TextCleanup.swift`).

Because the previous fragment is already pasted (with its capital letter and
trailing period) by the time the next fragment arrives, there is no way to repair
the boundary after the fact. **To produce natural text we must defer commit until
we have enough context to format the full thought.**

## Goals

1. Hands-Free output should read as continuous prose across natural mid-sentence
   pauses.
2. The user should retain control over *when* text lands in the target app.
3. The user should see what has been transcribed so far before it is committed.
4. Reuse the existing capture → detect → transcribe → post-process → deliver
   pipeline. No second transcription stack.
5. Preserve parity between the AVAudioEngine path and the `voicey-capture` worker
   path (the existing Hands-Free parity requirement still holds).

## Non-goals

- Wake-word / always-listening behavior.
- Editing the previewed text inside the overlay (read-only preview in v1).
- Streaming partial words *within* a single utterance (we still commit on
  utterance boundaries internally; we only defer the *paste*).
- New sensitivity sliders or VAD knobs.
- Changing Manual mode behavior.

## Why "just increase the timeout" is rejected

| Approach | Why it fails |
|----------|--------------|
| Longer `silenceHangoverDuration` | Delays every commit; still picks an arbitrary boundary; thinking pauses can exceed any fixed value. |
| Per-utterance smarter punctuation | The boundary period/capital is added before the next utterance exists; already-pasted text cannot be repaired. |
| Cross-utterance context hint to post-processor (incremental paste retained) | Helps the *next* clip avoid a leading capital, but cannot remove the trailing period already pasted on the *previous* clip. Partial fix only. |

The fragmentation is inherent to committing each utterance before the sentence is
known to be complete. Deferral is the structural fix.

## Solution options considered

### Option A — Deferred commit, paste once at session end (recommended core)

Keep segmenting + transcribing per utterance internally, but **accumulate** the
post-processed text in session state instead of pasting. Commit (paste) the whole
buffer once, at an explicit finish.

- Pros: produces natural continuous text; post-processing can run once over the
  joined transcript so punctuation/capitalization is coherent; minimal change to
  the VAD/capture layer.
- Cons: nothing lands in the target app until commit, so the user needs feedback
  — addressed by Option C.

### Option B — Incremental paste with stateful post-processing

Keep pasting each utterance, but feed prior context into post-processing and
suppress per-utterance capitalization/terminal punctuation.

- Pros: text still appears progressively in the target app.
- Cons: cannot retroactively fix the previous fragment's trailing period/capital;
  produces "lower-cased run-ons" that are also wrong; fragile. Rejected as a
  standalone fix.

### Option C — Live preview in the overlay + commit gesture (recommended companion)

Show the accumulated transcript in the existing floating overlay as each
utterance completes, and commit on an explicit finish gesture.

- Pros: restores the "I can see it working" feedback that Option A removes;
  natural home for the user's "show the transcribed text in the floating modal"
  request.
- Cons: adds an overlay text region and a commit/edit affordance.

### Recommendation

Ship **A + C**: accumulate per-utterance text into a session buffer, show it live
in the overlay, and paste the joined+post-processed result once on commit.

## Commit triggers

The session needs an unambiguous "I'm done" signal. Proposed triggers, in order
of confidence:

1. **End-session hotkey** (already exists): pressing the hotkey again ends the
   Hands-Free session. This becomes the primary commit point and maps cleanly
   onto today's `endHandsFreeSession()`.
2. **Enter / commit key while a session is active** (the user's "hit enter"):
   commit the buffer to the target app and either end the session or start a
   fresh paragraph.
3. **Escape**: cancel/discard the pending buffer without pasting (consistent with
   today's overlay cancel semantics).

### "Hit enter" — open design question

The overlay is intentionally *not* made key in Hands-Free mode so focus stays in
the target app (`TranscriptionOverlay.swift`). That makes capturing Enter
non-trivial. Candidate mechanisms:

- **Global/local event monitor for Return while a Hands-Free session is active.**
  Risk: intercepting Enter could swallow the user's real newline in the target
  app. Would need to only act when a non-empty pending buffer exists and likely
  consume the event.
- **Make the overlay key and route Enter to commit.** Risk: steals focus from the
  target app, which conflicts with auto-paste landing in the right place.
- **Dedicated commit affordance in the overlay** (button) plus the hotkey. Lowest
  risk, but less "hands-free".

Recommendation for v1: primary commit = end-session hotkey (no new global key
interception). Treat Enter-to-commit as a fast-follow once the focus/interception
trade-off is validated on-device. Document the decision rather than silently
shipping a global Return swallow.

## Design

### State model

Add session-scoped accumulation to `AppState` (`Sources/Voicey/App/AppState.swift`):

- `pendingHandsFreeTranscript: String` (or `[String]` of committed utterances) —
  `@Published`, the accumulated, post-processed text awaiting commit.
- Reset on session arm and after commit/cancel.

The existing `TranscriptionState` cases are sufficient; no new case is required.
`waitingForSpeech` / `recording` continue to describe capture; the pending buffer
is orthogonal session state.

### Per-utterance flow (changed)

In `processTranscription(..., continueHandsFreeSession: true)`
(`Sources/Voicey/App/AppDelegate.swift`):

1. Transcribe + post-process the utterance as today.
2. Instead of `outputManager?.deliver(...)`, **append** the processed text to
   `appState.pendingHandsFreeTranscript` using the existing inter-utterance
   spacing helper.
3. Restore `.waitingForSpeech` and update the overlay (live preview reflects the
   new text).
4. Keep the background-job tracking (`handsFreeBackgroundTranscriptionJobs`) so
   the overlay still shows in-flight transcription progress.

### Commit flow (changed)

At commit (`endHandsFreeSession()` and any future Enter handler):

1. Finalize the in-progress utterance audio as today.
2. Transcribe it, append to the pending buffer.
3. **Re-run post-processing once over the full joined transcript** so sentence
   capitalization and terminal punctuation are coherent across the whole thought
   (the key quality win). This needs a join that the post-processor can treat as
   one document rather than N sentences.
4. `outputManager?.deliver()` **once** with the final text.
5. Clear `pendingHandsFreeTranscript`, reset state to `.idle`, hide overlay.

Joining + final post-processing detail: today `PostProcessor` runs per utterance.
We need either (a) a mode that post-processes a concatenation of raw utterance
texts as a single passage, or (b) accumulate *raw* utterance text and only
post-process at commit. Option (b) is cleaner for punctuation coherence; the live
preview would then show lightly-cleaned (not fully punctuated) interim text, with
final formatting applied at commit. This trade-off (interim fidelity vs. final
coherence) should be decided during implementation.

### Overlay (live transcript)

Extend `TranscriptionOverlayView` (`Sources/Voicey/UI/TranscriptionOverlay.swift`):

- Add a scrollable, read-only text region bound to
  `appState.pendingHandsFreeTranscript`, shown only when a Hands-Free session is
  active and the buffer is non-empty.
- Keep the status label, waveform, and background-job strips.
- Keep the overlay non-key in Hands-Free mode (preserves target-app focus). If
  Enter-to-commit lands later, revisit.
- Constrain height / scroll so the overlay stays a temporary HUD, not a document
  editor (consistent with the original "temporary recording HUD" requirement).

### Paste target

On commit, decide between `recordingTargetPID` (app at session start) and current
frontmost. Today Hands-Free pastes to current frontmost
(`transcriptionPasteTargetPID`). With a single deferred commit, current frontmost
is still reasonable, but this should be confirmed: the user may have changed focus
during a long dictation. Recommendation: keep current-frontmost for parity with
today's Hands-Free behavior and call it out for QA.

### Auto-paste off

When `autoPasteEnabled` is false, commit copies the joined transcript to the
clipboard and notifies (existing `OutputManager` behavior) — now a single
clipboard payload instead of N overwrites, which is itself an improvement.

## Touchpoints

| Area | File | Change |
|------|------|--------|
| Session buffer state | `Sources/Voicey/App/AppState.swift` | Add `pendingHandsFreeTranscript`; reset helpers. |
| Per-utterance accumulate | `Sources/Voicey/App/AppDelegate.swift` (`processTranscription`) | Append instead of deliver when `continueHandsFreeSession`. |
| Commit | `Sources/Voicey/App/AppDelegate.swift` (`endHandsFreeSession`) | Join + final post-process + single deliver. |
| Spacing/join | `Sources/VoiceyCore/TextCleanup.swift` | Reuse / extend joining helper. |
| Final post-process | `PostProcessor` (voicey-text worker path) | Support post-processing a multi-utterance passage at commit. |
| Overlay preview | `Sources/Voicey/UI/TranscriptionOverlay.swift` | Bind read-only transcript region. |
| Optional Enter commit | `AppDelegate` event monitor / `KeyablePanel` | Deferred; document focus trade-off. |
| Localization | `Sources/Voicey/Utilities/Localization.swift` | Any new overlay copy. |

No changes required in the VAD detector
(`Sources/VoiceyCore/HandsFreeSpeechDetector.swift`) or capture worker — segment
boundaries stay the same; only downstream commit timing changes. This preserves
Swift/Rust capture parity for free.

## Risks & edge cases

- **No visible progress until commit.** Mitigated by the live overlay preview
  (Option C is not optional in practice).
- **Long sessions / unbounded buffer.** Keep the existing per-utterance max
  duration; consider a soft cap or scroll on the preview. Memory is just text.
- **Crash / app quit mid-session loses uncommitted text.** Acceptable for v1
  (matches today's "in-flight audio is ephemeral" model), but worth noting.
- **Enter interception swallowing real newlines.** The reason Enter-to-commit is
  deferred; do not ship a global Return swallow without on-device validation.
- **Empty utterances.** Continue to skip sub-0.5s clips; never append empty text.
- **Final post-process changing already-previewed text.** Expected; the preview
  is interim. Make sure the committed text matches what most users expect (final,
  cleanest version).

## Acceptance criteria

1. A sentence spoken with one or more mid-sentence pauses commits as a single
   coherent sentence, not fragmented capitalized clauses.
2. Nothing is pasted into the target app until an explicit commit (end-session
   hotkey in v1).
3. The overlay shows the accumulated transcript, updating after each utterance.
4. Escape during a Hands-Free session discards the pending buffer without
   pasting.
5. Final committed text is post-processed as one passage (coherent capitalization
   and terminal punctuation).
6. Manual mode is unchanged.
7. Behavior is materially identical on the AVAudioEngine and `voicey-capture`
   worker paths.
8. With auto-paste off, commit produces a single clipboard payload.

## Validation plan (macOS)

- Dictate a sentence with a deliberate 3–5s mid-sentence pause; confirm single
  coherent output.
- Multiple sentences with natural pauses; confirm correct sentence boundaries.
- End-session hotkey commits; Escape discards.
- Auto-paste on (text field + terminal target) and off (clipboard).
- Long dictation (many utterances) — overlay scroll + memory sanity.
- Worker path vs. Swift path parity.
- Manual mode regression.

## Deferred

- In-overlay editing of the pending transcript.
- Enter-to-commit (pending focus/interception decision).
- Paragraph/segment markers in the committed output.
- Per-user sensitivity or hangover tuning.
