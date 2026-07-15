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
| `Sources/Transcription/GroqService.swift` | Groq transcription API client — primes Whisper with the user glossary, rolling context, and a per-meeting `sessionGlossary` (Catalog entity names + people + taught voices) for accurate proper nouns |
| `Sources/Meetings/TextPolisher.swift` / `Sources/Services/AppDetector.swift` | Context-aware formatting; the unified `noteBrief`; the cached, Groq→Apple degrading generation path; map-reduce summarization for long meetings (`condenseIfNeeded`); timestamp-cited summaries; and per-meeting-type key-field extraction |
| `Sources/Services/AICache.swift` | On-disk cache for deterministic AI derivations (note briefs, follow-up drafts) in Application Support, keyed by content hash + model + prompt version |
| `Sources/Meetings/AppleIntelligence.swift` | On-device LLM wrapper (Apple Foundation Models, macOS 26+) — availability-gated summaries/briefs/follow-ups |
| `Sources/Transcription/OnDeviceNLP.swift` | On-device entity/topic tagging via Apple `NaturalLanguage` NER (universal — every Mac) |
| `Sources/Services/TextInjector.swift` | Text injection — Accessibility (`AXSelectedText`) with a clipboard-paste fallback; browsers are routed straight to paste, since web `contenteditable` fields (Gmail compose/chat, Google Docs) accept an AX set but often don't insert |
| `Sources/Services/BrowserURL.swift` | Reads the active browser tab's address for per-site styling |
| `Sources/Services/KeychainService.swift` | Groq API-key storage in the macOS Keychain |
| `Sources/Meetings/MeetingNotesWriter.swift` | Markdown transcript writer (front-matter, summaries, dated subfolders) |
| `Sources/Audio/SpeakerProfiler.swift` | Voice-fingerprint clustering for speaker diarization |
| `Sources/Audio/VoiceIdentityStore.swift` | Persistent named voice identities — matches diarized voices to saved names across meetings; learns from renames |
| `Sources/Meetings/MeetingDetector.swift` | Per-process mic inspection — call start/end detection |
| `Sources/Views/RenameSpeakersWindow.swift` | Per-meeting speaker renaming |
| `Sources/Transcription/OfflineTranscriber.swift` | On-device speech fallback (Apple Speech) |
| `Sources/Services/NotificationManager.swift` | Post-meeting, quick-note, and error notifications |
| `Sources/Meetings/NotesLibrary.swift` | `NotesLibrary` — shared notes data layer (file listing, hybrid search, cross-meeting excerpts, action-item parsing) |
| `Sources/Meetings/DigestService.swift` | Builds the proactive daily/weekly digest model + archived note (meetings, open/overdue action items, quiet relationships) |
| `Sources/Views/DigestWindow.swift` | Interactive digest window — tickable action items, overdue highlighting, click-to-open |
| `Sources/Views/AskWindow.swift` | Multi-turn "Ask your notes" chat with a scope selector (all / chosen meetings / org / project) and cited sources |
| `Sources/Transcription/SemanticIndex.swift` | On-device hybrid search over notes — blends `NLEmbedding` cosine similarity (meaning) with a BM25 lexical score (exact words/names), reranked with an exact-phrase bonus + recency boost; cached on disk. Lexical half runs even when no embedding model exists |
| `Sources/Meetings/LiveMeetingAssistant.swift` | Floating in-meeting brief + grounded Ask (rolling TL;DR / actions) |
| `Sources/Views/NotesViewerWindow.swift` | In-app Markdown viewer/editor — **rendered Markdown when reading** (headings, bullets, task lists, quotes, code fences, tables, rules, inline styling, front-matter Properties box); a **Contents** table-of-contents sidebar (headings + timestamped chapters), **word-level find** highlighting (only the matched phrase, with an accent-tinted active match and nonce-driven scroll-to), and **clickable chapter bullets** that resolve a `[timestamp]` to the matching transcript line; raw monospaced editor with the native find bar when unlocked to edit; Summarize brief + Regenerate, a Draft… menu (per-type documents + a one-click **Follow-Up Packet**), rename, PDF export. Honors the "open notes in external editor" setting, which routes every note-open to the OS default `.md` app instead |
| `Sources/Models/Catalog.swift` | Catalog model + `CatalogStore` (Codable `Catalog.json` store: orgs/projects plus per-note people/tags, org hierarchy, project→org inheritance, import, missing-file reconcile, purge) |
| `Sources/Views/Catalog/CatalogWindow.swift` | Catalog window — three-column browser, Map tree (per-note people/tags, expand/collapse, shared org/project scope picker + `DateRange` filter via `MapFilter`, People/Tags leaf toggles), note linking, per-entity relationship timeline, search (Text/Meaning/Ask) + consolidated Filter menu with removable chips, row actions, Quick add, catalog export/import. Sidebar groups: Overview · Browse · Records (orgs, projects, people, tags) · Track (Open Questions grouped by date Year→Month→Day, POC Tracker, Keyword Radar). Notes and Open Questions share the collapsible date grouping and the `DateRange` time-window filter |
| `Sources/Views/Catalog/OrgProjectTreePicker.swift` | The single reusable searchable, indented **org→project tree** chooser (scope: both / orgs-only / projects-only; optional clear row; exclusion set). Used by Assign, Ask scope, audio-import "File under", the Notes / Open Questions / POC Tracker filters, the entity editors' parent/org pickers, the dashboard account filter, and the Start-Meeting link |
| `Sources/Views/Catalog/DateGrouping.swift` | Shared date primitives reused across dated Catalog surfaces: the `DateRange` time-window enum (default **30 days**) + its `includes(_:)` test, the `RangePicker` segmented control, `DateGrouping.tree(_:dateOf:)` (builds a newest-first Year→Month→Day node tree with an "Undated" bucket), `DateGroupDisclosure` (nested `DisclosureGroup`s with a shared expand/collapse key set), `ExpandCollapseButton`, `ResetButton` (the one app-wide reset control), and the POC-deadline primitives `DeadlineState` (overdue/today/soon/upcoming with colour + label) and its `DeadlineBadge` pill (reused by the POC Tracker rows, `PocDetail`, and the Dashboard POC card). Used by the Dashboard filter, Notes, Open Questions, POC Tracker, Keyword Radar, and Map |
| `Sources/Views/Catalog/CatalogWindow.swift` (POC section) | POC tracker — a **Track › POC Tracker** section inside the Catalog. A project owns **many `Poc` records** (`Poc`: name, `detail`, `phase` (`PocPhase`), `criteria`, `startDate`, `deadline`); the master list (`PocProjectList`) is a flat list of POCs (`PocRow` = project + poc), one row per POC. Dashboard-style tracker: stats strip (incl. due-soon count), search, `＋ New POC` (`NewPocSheet` → `CatalogStore.addPoc`), labeled Status selector (`PocStatusSel` — **Open** (default) / Closed / All via `PocPhase.isOpen`, or a specific `PocPhase`) + badged Filter menu (health `PocState`) + account + `DateRange` — a ranged view keeps POCs with activity **or** a deadline in-window), Group-by (`PocGroup`: Phase/Health/**Account (default)**/Project/Date/None) and Sort (`PocSort`: At-risk first/**Deadline**/Name/Progress/Recent) with collapsible groups; per-row health icon (`PocState`), `PhasePill`, project·account path, progress bar, `DeadlineBadge`, last-activity, plus an expandable drill-down to the project's linked notes. Detail pane (`PocDetail`, keyed by POC id) edits the POC's name/phase/description, **start + target dates** (`setPocStartDate`/`setPocDeadline`), and its **success-criteria tree**: criteria form an **unlimited hierarchy** via `PocCriterion.parentID` — `critNodes` flattens it pre-order honoring collapsed sub-trees, each row has ▲/▼ to reorder among siblings (`movePocCriterion`, sub-tree moves with it), a ＋ to add a child (`addPocCriterion(_:parentID:…)`), and a remove that drops the whole sub-tree (`removePocCriterion`); **Bulk add** (`PocBulkAddSheet` → `parseBulk` → `addPocCriteriaTree`) parses a pasted indented list into a hierarchy (line breaks are the only separator — commas are kept), parents show a rolled-up leaf tally while only **leaves** carry pass/fail (`Poc.leaves` drives all tallies). Also **Clear all criteria** (`clearPocCriteria(pocID:in:)`) and **Delete POC** (`removePoc`), plus **Suggest from meetings** (`TextPolisher.extractPocCriteria`, adds at top level). Legacy single-POC catalogs migrate to one `Poc` on decode. State stored on the project in `Catalog.json` |
| `Sources/Views/Catalog/CatalogDashboard.swift` | Catalog **Dashboard** (Overview section) — SE-oriented insight cards (POC command center, relationships, activity, **meeting-type mix** funnel — Discovery → Demo → Scoping → Kickoff, action items, competitive/product intelligence, open technical questions) + an "At a glance" KPI strip that honors both filters: the whole-catalog structural snapshot under "All time", or window-scoped (entities touched by a meeting in the range) once a range/account is chosen, with the header naming the active scope. Time range (shared `DateRange`, default **30 days**) spans Today → All time. Uses Swift Charts. Aggregation reuses `DigestService`, `NotesLibrary.actionItems`, and `RadarInsights` |
| `Sources/Views/Catalog/RadarInsights.swift` | Cross-meeting Keyword-Radar rollup — a **Track › Keyword Radar** section inside the Catalog (term list → source meetings, shared-scan `RadarModel`); `RadarInsights.aggregate` re-scans note bodies against the current watchlist. Term list has a stats strip, an inline add-keyword field (`addWatchlistTerms`), search, the shared org/project scope picker (re-tallies stats from scoped hits), sort (`RadarSort`), a `DateRange` last-mention filter, optional Year→Month→Day grouping (`RadarGroup`, via `DateGrouping`), and a Reset. `RadarTermDetail` is a drill-down: summary stats, a tappable Swift Charts bar chart of accounts/projects mentioning the term, and source meetings scoped to the tapped account. Dashboard/Notes/Map/POC/Radar all use one shared `ResetButton` (single `arrow.uturn.backward` icon) for search+filters+group+range |
| `Sources/Services/EventDispatcher.swift` | Outbound meeting-finished event hooks — local script (JSON on stdin) and HTTPS webhook; metadata-only, redaction-aware, suppressed in Local-only mode |
| `Sources/Meetings/FollowUpPacket.swift` | One-click **Follow-Up Packet** — assembles a user-chosen, reorderable set of sections (`packetSectionIDs`, default follow-up email → POC plan → action items) drawn from the draft-document catalog into one Markdown document. Sections run concurrently and degrade individually; the three curated ones keep their special grounding wherever they sit (meeting-type email, the project's current success criteria, the note's curated `## Action Items`). Sections are picked/reordered in Settings → Draft Templates; opened via the notes viewer's Draft… menu |
| `Sources/Utils/MarkdownPDF.swift` | Paginated Markdown → PDF renderer (CoreText) — title/Properties header, clickable page-numbered TOC, POC section; navy/cyan palette matching the app icon |
| `Sources/Utils/WindowHelpers.swift` | Shared `NSWindowController.bringToFront()` present helper |
| `Sources/Utils/FlowLayout.swift` | Shared wrap-to-width `Layout` for chip rows (one implementation for Catalog + notes-viewer chips) |
| `Sources/Utils/FrontMatter.swift` | Shared YAML front-matter split/strip/`field(_:in:)` helper (one implementation for all note-body extraction; Dictations + Catalog + Dashboard all route through it) |
| `Sources/Utils/DateDisplay.swift` | Shared date formatters — cached `posixDay`/`posixTimestamp`, the display formatter, a `posixFormatter(_:)` factory (month keys, organized-folder stamps), a shared `iso8601` writer, and `parseISO(_:)` (fractional-tolerant, replaces the duplicated `isoDate` helpers in PDF export + note viewer) |
| `Sources/Utils/FileText.swift` | `URL.readText()` — one UTF-8 file-read helper replacing the `try? String(contentsOf:encoding:)` boilerplate that was repeated at ~28 call sites |
| `Sources/Services/RemindersExporter.swift` | Export action items to Apple Reminders (EventKit) |
| `Sources/Services/BackupService.swift` | Full backup/restore — zips notes, quick notes, dictations & Catalog |
| `Sources/Views/DictationsWindow.swift` | Master–detail browser for archived dictations — searchable/app-filterable/sortable day-grouped list + stats bar on the left, full-text detail with Copy / Open / Reveal / Delete on the right; Select mode for bulk Copy / Delete |
| `Sources/Services/Redactor.swift` | Opt-in redaction of emails / phones / long numbers |
| `Sources/Utils/Diagnostics.swift` | In-memory recent-errors log for the Diagnostics pane |
| `Sources/Models/UsageStats.swift` | Local usage counters + Groq cost estimate |
| `Sources/Services/PermissionGuard.swift` | Mic / Accessibility / System-audio permission handling |
| `Sources/Models/AppSettings.swift` | UserDefaults-backed settings store with defaults |
| `Sources/Utils/Log.swift` | os.Logger categories (visible in Console.app) |
| `Sources/Views/SettingsView.swift` | Sidebar-style settings window (SwiftUI) with a curated global **search** across panes. Sidebar groups: Essentials/General/AI on top, then Capture · Meetings · Automation (Digest + Integrations) · Privacy & Security · System · Account (Usage & Cost + About). Recording → Advanced exposes the detection/timing constants (poll interval, STT timeout, live-brief growth) |
| `Sources/Views/APIKeyView.swift` | API-key onboarding UI (SwiftUI) |
| `Sources/Views/GlowOverlayView.swift` | Floating recording indicator / live-caption overlay |
| `Sources/Views/MeetingPrepWindow.swift` | Non-modal meeting-prep panel — recent notes for the linked org/opp |
| `Sources/Utils/DateDisplay.swift` | Date formatting for the menu, Catalog, and note lists |
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
| **Reminders** (optional) | Export meeting action items to the Reminders app (from the Catalog and Today's Digest). Prompted only on first export; decline and the rest of the app is unaffected. |

macOS keys each grant to the app's code signature, so re-signing with a different identity resets them. If a permission gets stuck, use **Reset All Permissions…** from the menu (it also clears the Automation and Reminders grants).
