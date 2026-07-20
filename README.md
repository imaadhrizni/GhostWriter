# 👻 GhostWriter

> A zero-latency, context-aware macOS dictation agent that magically types polished text into any active window — and now transcribes your meetings.

GhostWriter is a lightweight native macOS utility that lives in your menu bar. Hold down the **Right Option** key to speak, and GhostWriter instantly transcribes and polishes your speech using Groq's ultra-fast Whisper and Llama models, injecting the perfect text directly into whatever app you're currently using.

It also has a **Meeting Mode** that captures both sides of a conversation — your microphone *and* the system audio (the other participants) — and writes a live, speaker-attributed transcript to a Markdown notes file.

## Highlights

- **Zero-latency dictation** — hold Right Option, speak, release; Groq `whisper-large-v3` transcribes (streaming for long dictations) and a Llama model (default `llama-4-scout`) polishes to match the app you're typing in.
- **Meeting Mode** — captures your mic *and* system audio via CoreAudio process taps (no screen-recording permission), producing a timestamped, speaker-labeled transcript with AI summaries, action items, and a live in-meeting brief. Draft documents from any meeting — minutes, follow-up email, status update, and more — each with editable, configurable guidance, or a one-click **Follow-Up Packet** bundling the follow-up email, an updated POC plan, and action items into a single exportable document.
- **Ask Your Notes** — a multi-turn chat grounded in your meeting archive, scoped to all meetings, a chosen set, or an org/project, with cited sources. (Browsing, text/semantic search, and action-item export to Reminders live in the Catalog and Digest.)
- **Catalog** — a CRM-style graph of the organisations, people, projects and tags your meetings are about, sitting beside your notes without touching them. People are organised under a hierarchical, user-defined **Type** vocabulary, and the People, Tags, and Notes lists support **bulk** add, assign, and delete. Opens on a **Dashboard** built for sales engineers: POC command center, a meeting-type mix funnel (Discovery → Demo → Scoping → Kickoff), open technical questions, action items, competitive/product signals, engagement, and relationships going quiet — plus a **POC Tracker** for proof-of-concept success criteria and a **Reports** builder that exports scoped, selectable insight reports to PDF/Markdown.
- **Insights & integrations** — a cross-meeting **Keyword Radar Insights** view (which competitors/products come up, how often, where), **template import/export** to back up or share your meeting & draft templates, and outbound **event hooks** (local script or webhook) that fire when a meeting finishes so you can wire GhostWriter into Notion, Slack, or Zapier.
- **Private by default** — Local-Only mode keeps everything on-device, including AI summaries via **Apple Intelligence** and entity/topic tags via **NaturalLanguage**; opt-in redaction; API key in the Keychain; semantic search runs on Apple's on-device `NLEmbedding`. On-device AI also serves as a Groq fallback and can be preferred outright while keeping Groq for transcription.

See **[Features](docs/features.md)** for the full list.

## Quick Start

Because GhostWriter relies on global hotkeys, accessibility, and system-audio capture, it must be packaged and code-signed cleanly so macOS attributes permissions to the app itself.

```bash
./ship.sh
```

This compiles, bundles, code-signs, installs in-place to `/Applications`, and launches the app. On first launch, open **Settings** — the **Essentials** pane shows a live checklist for the three things you need: a [Groq API Key](https://console.groq.com/keys) (`gsk_…`), **Microphone**, and **Accessibility** (plus **System Audio Recording** for meetings). It flips to "You're all set" once they're granted.

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
