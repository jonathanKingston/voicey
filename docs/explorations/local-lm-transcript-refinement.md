# Local language model transcript refinement

## Status

**Explored and implemented** in PR (settings + localhost OpenAI-compatible refinement). No prior LM Studio / Ollama integration existed in the repo before this work.

## Problem

Qwen3 ASR decoder steering improves spelling for names and on-screen terms, but long steering context can garble recognition (#162 follow-ups, session-archive replay). A separate local language model can apply vocabulary and screen context **after** transcription instead of biasing the speech model.

## Design

When **Refine transcription with a local language model** is enabled in Settings → Spelling & Context:

1. Glossary and screen-context terms are still harvested at record start.
2. **Qwen3 ASR does not receive `decoder_context`** (steering bypass).
3. Raw transcript is sent to a **localhost-only** OpenAI-compatible `/v1/chat/completions` endpoint (LM Studio default `http://127.0.0.1:1234/v1`, Ollama `http://127.0.0.1:11434/v1`).
4. Vocabulary / decoder context is included in the chat user message.
5. `voicey-text` post-processing still runs for voice commands and expansions; steering-echo sanitization is skipped because Qwen was not steered.

## Settings

| Key | Default | Purpose |
|-----|---------|---------|
| `localLMRefinementEnabled` | `false` | Master toggle |
| `localLMBaseURL` | `http://127.0.0.1:1234/v1` | OpenAI-compatible base URL (localhost only) |
| `localLMModelName` | `local-model` | Model id for chat completions |

## Non-goals

- Cloud LLM providers (localhost-only for privacy).
- Replacing Qwen ASR or the Rust `voicey-text` worker.
- Auto-detecting loaded models from the local server.

## macOS validation

1. Start LM Studio (or Ollama) with a loaded chat model.
2. Enable local LM refinement; set base URL and model name.
3. Dictate jargon from glossary / on-screen text — spelling fixes should come from the local LM, not Qwen steering echoes.
4. Disable the toggle — Qwen decoder steering should resume.
