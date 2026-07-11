# 🛠 Architecture

[← Back to README](../README.md) · [Features](features.md) · [Usage](usage.md) · [Settings](settings.md)

## Tech Stack

- **Language:** Swift (macOS **14.2+** — required for CoreAudio process taps)
- **Dictation audio:** `AVFoundation` — 16 kHz PCM capture with RMS-based Voice Activity Detection.
- **System audio:** CoreAudio process taps — `CATapDescription` → `AudioHardwareCreateProcessTap` → aggregate device → direct `AudioDeviceIOProc` callback, converted to 16 kHz mono via `AVAudioConverter`. Uses only the **System Audio Recording** permission (`NSAudioCaptureUsageDescription`), not Screen Recording.
- **Input/Output:** `CoreGraphics` CGEvent taps for the global hotkey; `ApplicationServices` `AXUIElement` API for text injection.
- **UI:** SwiftUI for the API-key onboarding and the floating recording indicator.
- **AI backend:** REST calls to Groq's Whisper (`whisper-large-v3`) for transcription and a configurable Llama/OpenAI-OSS/Qwen chat model (default `llama-4-scout`) for polishing & summaries, with an on-device path via Apple **Foundation Models** (the Apple Intelligence LLM, macOS **26+**) for summaries/briefs/follow-ups and Apple **NaturalLanguage** for entity/topic tagging. On-device is used in Local-only mode, when "Prefer on-device AI" is on, and as an automatic fallback when Groq fails. Deterministic derivations (note briefs, follow-up drafts) are cached on disk (see `AICache`).
- **Logging:** unified `os.Logger` with per-feature categories. Rare lifecycle events at info, errors/warnings always persisted, high-frequency events at debug (transcript content is privacy-redacted). Inspect with:
  ```bash
  log stream --predicate 'subsystem BEGINSWITH "com.ghostwriter"' --level debug
  ```

## Project Layout

| Path | Purpose |
| --- | --- |
| `Sources/Services/HotkeyManager.swift` | Global hotkeys (push-to-talk, Esc, ⌃⌥ shortcuts) via CGEvent tap |
| `Sources/Audio/AudioCapture.swift` | Microphone capture |
| `Sources/Audio/VoiceActivityDetector.swift` | RMS-based voice-activity detection |
| `Sources/Audio/SystemAudioCapture.swift` | System-audio capture via CoreAudio process taps |
| `Sources/Transcription/GroqService.swift` | Groq transcription + polishing API client |
| `Sources/Meetings/TextPolisher.swift` / `Sources/Services/AppDetector.swift` | Context-aware formatting; also the unified `noteBrief` and the cached, Groq→Apple degrading generation path |
| `Sources/Services/AICache.swift` | On-disk cache for deterministic AI derivations (note briefs, follow-up drafts) in Application Support, keyed by content hash + model + prompt version |
| `Sources/Meetings/AppleIntelligence.swift` | On-device LLM wrapper (Apple Foundation Models, macOS 26+) — availability-gated summaries/briefs/follow-ups |
| `Sources/Transcription/OnDeviceNLP.swift` | On-device entity/topic tagging via Apple `NaturalLanguage` NER (universal — every Mac) |
| `Sources/Services/TextInjector.swift` | Accessibility-based text injection |
| `Sources/Services/BrowserURL.swift` | Reads the active browser tab's address for per-site styling |
| `Sources/Services/KeychainService.swift` | Groq API-key storage in the macOS Keychain |
| `Sources/Meetings/MeetingNotesWriter.swift` | Markdown transcript writer (front-matter, summaries, dated subfolders) |
| `Sources/Audio/SpeakerProfiler.swift` | Voice-fingerprint clustering for speaker diarization |
| `Sources/Audio/VoiceIdentityStore.swift` | Persistent named voice identities — matches diarized voices to saved names across meetings; learns from renames |
| `Sources/Meetings/MeetingDetector.swift` | Per-process mic inspection — call start/end detection |
| `Sources/Views/RenameSpeakersWindow.swift` | Per-meeting speaker renaming |
| `Sources/Transcription/OfflineTranscriber.swift` | On-device speech fallback (Apple Speech) |
| `Sources/Services/NotificationManager.swift` | Post-meeting, quick-note, and error notifications |
| `Sources/Meetings/NotesAssistant.swift` | `NotesLibrary` — shared notes data layer (file listing, text/semantic search, cross-meeting excerpts, action-item parsing) |
| `Sources/Meetings/DigestService.swift` | Builds the proactive daily/weekly digest model + archived note (meetings, open/overdue action items, quiet relationships) |
| `Sources/Views/DigestWindow.swift` | Interactive digest window — tickable action items, overdue highlighting, click-to-open |
| `Sources/Views/AskWindow.swift` | Multi-turn "Ask your notes" chat with a scope selector (all / chosen meetings / org / opportunity) and cited sources |
| `Sources/Transcription/SemanticIndex.swift` | On-device semantic search over notes (Apple `NLEmbedding`, cached) |
| `Sources/Meetings/LiveMeetingAssistant.swift` | Floating in-meeting brief + grounded Ask (rolling TL;DR / actions) |
| `Sources/Views/NotesViewerWindow.swift` | In-app Markdown viewer/editor (find bar, read-only/unlock-to-edit, Summarize brief + Regenerate, follow-up, rename, PDF export, open externally) |
| `Sources/Models/Catalog.swift` | Catalog model + `CatalogStore` (Codable `Catalog.json` store: orgs/projects/opportunities plus per-note people/tags, org hierarchy, project→org inheritance, import, missing-file reconcile, purge) |
| `Sources/Catalog/CatalogWindow.swift` | Catalog window — three-column browser, Map tree (per-note people/tags, expand/collapse), note linking, per-entity relationship timeline, search (Text/Meaning/Ask) + consolidated Filter menu with removable chips, row actions, Quick add, catalog export/import |
| `Sources/Utils/MarkdownPDF.swift` | Paginated Markdown → PDF renderer (CoreText) |
| `Sources/Utils/WindowHelpers.swift` | Shared `NSWindowController.bringToFront()` present helper |
| `Sources/Services/RemindersExporter.swift` | Export action items to Apple Reminders (EventKit) |
| `Sources/Services/BackupService.swift` | Full backup/restore — zips notes, quick notes, dictations & Catalog |
| `Sources/Views/DictationsWindow.swift` | Searchable, day-grouped browser for archived dictations |
| `Sources/Services/Redactor.swift` | Opt-in redaction of emails / phones / long numbers |
| `Sources/Utils/Diagnostics.swift` | In-memory recent-errors log for the Diagnostics pane |
| `Sources/Models/UsageStats.swift` | Local usage counters + Groq cost estimate |
| `Sources/Services/PermissionGuard.swift` | Mic / Accessibility / System-audio permission handling |
| `Sources/Models/AppSettings.swift` | UserDefaults-backed settings store with defaults |
| `Sources/Utils/Log.swift` | os.Logger categories (visible in Console.app) |
| `Sources/Views/SettingsView.swift` | Sidebar-style settings window (SwiftUI) |
| `Sources/Views/APIKeyView.swift` | API-key onboarding UI (SwiftUI) |
| `Sources/Views/GlowOverlayView.swift` | Floating recording indicator / live-caption overlay |
| `Sources/Views/MeetingPrepWindow.swift` | Non-modal meeting-prep panel — recent notes for the linked org/opp |
| `Sources/Utils/DateDisplay.swift` | Date formatting for the menu & Notes Assistant |
| `Sources/App/GhostWriterApp.swift` | Menu-bar app, meeting mode, permission flow |
| `Sources/App/main.swift` | Executable entry point |
| `ship.sh` | Build, bundle, sign, and install to `/Applications` |
| `make_icon.swift` | Generates the app icon (`GhostWriter.icns`) |

## Permissions Explained

| Permission | Why it's needed |
| --- | --- |
| **Microphone** | Capture your speech for dictation and your side of meetings. |
| **System Audio Recording** | Capture the other participants' audio in Meeting Mode (via process taps). |
| **Accessibility** | Detect the Right Option hotkey globally and inject text at your cursor. |
| **Automation** (optional) | Read the active browser tab's address for per-site dictation styling (Safari + Chromium browsers). Prompted only on first use, per browser; decline and browser dictation just uses the generic Browser style. |
| **Reminders** (optional) | Export meeting action items to the Reminders app (Notes Assistant → Action Items). Prompted only on first export; decline and the rest of the app is unaffected. |

macOS keys each grant to the app's code signature, so re-signing with a different identity resets them. If a permission gets stuck, use **Reset All Permissions…** from the menu (it also clears the Automation and Reminders grants).
