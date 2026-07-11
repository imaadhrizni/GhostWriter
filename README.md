# 👻 GhostWriter

> A zero-latency, context-aware macOS dictation agent that magically types polished text into any active window — and now transcribes your meetings.

GhostWriter is a lightweight native macOS utility that lives in your menu bar. Hold down the **Right Option** key to speak, and GhostWriter instantly transcribes and polishes your speech using Groq's ultra-fast Whisper and Llama models, injecting the perfect text directly into whatever app you're currently using.

It also has a **Meeting Mode** that captures both sides of a conversation — your microphone *and* the system audio (the other participants) — and writes a live, speaker-attributed transcript to a Markdown notes file.

## Highlights

- **Zero-latency dictation** — hold Right Option, speak, release; Groq `whisper-large-v3` transcribes (streaming for long dictations) and `llama-3.3-70b-versatile` polishes to match the app you're typing in.
- **Meeting Mode** — captures your mic *and* system audio via CoreAudio process taps (no screen-recording permission), producing a timestamped, speaker-labeled transcript with AI summaries, action items, and a live in-meeting brief.
- **Notes Assistant** — browse, text/semantic-search, and Ask across your whole meeting archive with cited sources; export action items to Apple Reminders.
- **Catalog** — a CRM-style graph of the organisations, people, projects, opportunities and tags your meetings are about, sitting beside your notes without touching them.
- **Private by default** — Local-Only mode keeps everything on-device, including AI summaries via **Apple Intelligence** and entity/topic tags via **NaturalLanguage**; opt-in redaction; API key in the Keychain; semantic search runs on Apple's on-device `NLEmbedding`. On-device AI also serves as a Groq fallback and can be preferred outright while keeping Groq for transcription.

See **[Features](docs/features.md)** for the full list.

## Quick Start

Because GhostWriter relies on global hotkeys, accessibility, and system-audio capture, it must be packaged and code-signed cleanly so macOS attributes permissions to the app itself.

```bash
./ship.sh
```

This compiles, bundles, code-signs, installs in-place to `/Applications`, and launches the app. On first launch, enter a [Groq API Key](https://console.groq.com/keys) (`gsk_…`) and grant **Microphone**, **System Audio Recording**, and **Accessibility** when prompted.

Full walkthrough in **[Installation, Setup & Usage](docs/usage.md)**.

## Documentation

| Doc | What's inside |
| --- | --- |
| **[Features](docs/features.md)** | The complete feature catalog |
| **[Usage](docs/usage.md)** | Installation, first launch, dictation, Meeting Mode, quick notes, menu bar, and global shortcuts |
| **[Settings](docs/settings.md)** | Every settings pane and its defaults |
| **[Architecture](docs/architecture.md)** | Tech stack, project layout, and permissions explained |

---
*Built natively for Apple Silicon and macOS.*
