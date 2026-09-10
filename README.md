<p align="center">
  <img src="Resources/AppIcon-Source.png" width="128" height="128" alt="FreeFlow icon">
</p>

<h1 align="center">FreeFlow</h1>

<p align="center">
  Free and open source alternative to <a href="https://wisprflow.ai">Wispr Flow</a>, <a href="https://superwhisper.com">Superwhisper</a>, and <a href="https://monologue.to">Monologue</a>.
</p>

<p align="center">
  <b>FreeFlow Notes fork</b><br>
  <sub>Build locally with <code>make run</code> on macOS (Apple Silicon + Intel)</sub>
</p>

---

<p align="center">
  <img src="Resources/demo.gif" alt="FreeFlow demo" width="600">
</p>

<p align="center">
  <i>Thank you to <a href="https://github.com/marcbodea">@marcbodea</a> for maintaining FreeFlow!</i>
</p>

## Overview

FreeFlow Notes is a free Mac dictation and Markdown notes app. It gives you fast AI transcription and context-aware cleanup without a monthly subscription, then saves each completed dictation as a local Markdown note.

## Quick Start

1. Clone this fork, then run `make run` to build and launch FreeFlow Notes
2. Get a free Groq API key from [groq.com](https://groq.com/)
3. Hold `Fn` to talk, or tap `Command-Fn` to start and stop dictation. FreeFlow Notes post-processes the transcript into Markdown and opens it in the notes window.

The Makefile automatically signs local builds with the first Apple Development certificate on the Mac when one is available. This keeps macOS Accessibility consent valid across rebuilds. If no development certificate is installed, builds use ad-hoc signing; macOS may then require Accessibility to be removed and added again after each rebuild.

## Markdown Notes

After setup, the notes window opens automatically. Use the sidebar to browse previous notes or search their contents. Select a note and choose **Move note** to place it in a folder; nested folders such as `Projects/Ideas` are supported. **Preview** renders Markdown, and **Show files** opens the local notes folder. Notes are stored as UUID-named `.md` files under `~/Library/Application Support/FreeFlow Notes/notes`, so they remain portable and editable with any text editor.

The note-taking system prompt is editable in Settings → Prompts → Note-taking Prompt. Recordings longer than 90 seconds are split into ordered WAV chunks with a short overlap at each boundary so words are not cut between requests. The resulting sections are formatted separately and merged in passes so one very long recording can become a single coherent note without exceeding a model request size. Note transcription and formatting requests allow up to two minutes each; the normal dictation timeout remains configurable separately.

## Features

- **Custom shortcuts:** Customize both hold-to-talk and toggle dictation shortcuts. If your toggle shortcut extends your hold shortcut, you can start in hold mode and press the extra modifier keys to latch into tap mode without stopping the recording.
- **Context-aware cleanup:** FreeFlow can read nearby app context so names, terms, and phrases are spelled correctly when you dictate into email, terminals, docs, and other apps.
- **Custom vocabulary:** Add names, jargon, and project-specific words that FreeFlow should preserve during cleanup.
- **OpenAI-compatible providers:** Use Groq by default, or configure a custom model and API URL in settings.

## Edit Mode

Edit Mode lets you highlight existing text and transform it with a spoken instruction, like "make this shorter" or "turn this into bullets." Enable it in settings, then use your normal dictation shortcut on selected text, or choose Manual mode to require an extra modifier key.

## Privacy

There is no FreeFlow server, so FreeFlow does not store or retain your data. The only information that leaves your computer are API calls to your configured transcription and LLM provider.

## Custom Cleanup

If you'd rather keep cleanup more literal and less context-aware, you can paste this simpler prompt into the custom system prompt setting:

<details>
  <summary>Simple post-processing prompt</summary>

  <pre><code>You are a dictation post-processor. You receive raw speech-to-text output and return clean text ready to be typed into an application.

Your job:
- Remove filler words (um, uh, you know, like) unless they carry meaning.
- Fix spelling, grammar, and punctuation errors.
- When the transcript already contains a word that is a close misspelling of a name or term from the context or custom vocabulary, correct the spelling. Never insert names or terms from context that the speaker did not say.
- Preserve the speaker's intent, tone, and meaning exactly.

Output rules:
- Return ONLY the cleaned transcript text, nothing else. So NEVER output words like "Here is the cleaned transcript text:"
- If the transcription is empty, return exactly: EMPTY
- Do not add words, names, or content that are not in the transcription. The context is only for correcting spelling of words already spoken.
- Do not change the meaning of what was said.

Example:
RAW_TRANSCRIPTION: "hey um so i just wanted to like follow up on the meating from yesterday i think we should definately move the dedline to next friday becuz the desine team still needs more time to finish the mock ups and um yeah let me know if that works for you ok thanks"

Then your response would be ONLY the cleaned up text, so here your response is ONLY:
"Hey, I just wanted to follow up on the meeting from yesterday. I think we should definitely move the deadline to next Friday because the design team still needs more time to finish the mockups. Let me know if that works for you. Thanks."</code></pre>
</details>

## Using a Local Model

FreeFlow can use OpenAI-compatible local or self-hosted providers instead of Groq. In settings, configure the API base URL and model IDs for your local LLM provider, such as Ollama, LM Studio, or another OpenAI-compatible server. If your transcription backend uses a different endpoint from your LLM backend, set the transcription API URL separately.

Local models are often slower than hosted providers, especially on cold start, long recordings, or busy hardware.

For fully local speech-to-text, open Settings → Provider Settings, change **Transcription Engine** to **Local Whisper**, and choose a `whisper-cli` executable plus a Whisper `.bin` or `.gguf` model. The app runs that executable locally for every audio chunk; no transcription API key is used. The Homebrew `whisper-cpp` package provides `whisper-cli`, and whisper.cpp can use Metal on Apple Silicon. Download a model separately because the package does not include model files.

<details>
  <summary>Configure longer timeouts for local models</summary>

  FreeFlow keeps the default network timeout at 20 seconds, but you can extend it with macOS defaults:

```bash
defaults write com.zachlatta.freeflow transcription_timeout_seconds -float 120
defaults write com.zachlatta.freeflow post_processing_timeout_seconds -float 120
defaults write com.zachlatta.freeflow context_request_timeout_seconds -float 120
```

The timeout keys are:

- `transcription_timeout_seconds`: audio transcription requests
- `post_processing_timeout_seconds`: transcript cleanup and edit mode requests
- `context_request_timeout_seconds`: nearby app context requests

Only positive values are used. Remove a custom timeout to return to the 20-second default:

```bash
defaults delete com.zachlatta.freeflow transcription_timeout_seconds
defaults delete com.zachlatta.freeflow post_processing_timeout_seconds
defaults delete com.zachlatta.freeflow context_request_timeout_seconds
```

</details>

## License

Licensed under the MIT license.
