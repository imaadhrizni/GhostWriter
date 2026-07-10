# 👻 GhostWriter

> A zero-latency, context-aware macOS dictation agent that magically types polished text into any active window — and now transcribes your meetings.

GhostWriter is a lightweight native macOS utility that lives in your menu bar. Hold down the **Right Option** key to speak, and GhostWriter instantly transcribes and polishes your speech using Groq's ultra-fast Whisper and Llama models, injecting the perfect text directly into whatever app you're currently using.

It also has a **Meeting Mode** that captures both sides of a conversation — your microphone *and* the system audio (the other participants) — and writes a live, speaker-attributed transcript to a Markdown notes file.

## ✨ Features

- **Zero-Latency Dictation:** Powered by Groq's `whisper-large-v3` for near-instant speech-to-text. Long dictations stream — chunks are transcribed while you're still speaking, so releasing the key types almost instantly.
- **Voice Commands:** Say "new paragraph", spoken punctuation ("comma", "question mark"), "scratch that", or "all caps … end caps" while dictating — the rule list is editable in Settings.
- **Call Detection:** When Zoom, Teams, Webex, Slack, or a browser call (Google Meet) starts using your microphone, GhostWriter offers to start Meeting Mode — and offers to stop and save the notes when the call ends.
- **Quick Notes (⌃⌥J):** Toggle-dictate a thought from anywhere into a per-day notes file — transcribed, polished, timestamped, with click-to-open notifications.
- **Meeting Templates:** Nine built-in meeting types (Customer Call, Standup, 1:1, Interview, Planning, Retrospective, Lecture, Brainstorm, General) each extract their own summary sections — chosen right in the start-meeting dialog. Edit any template's **summary sections and follow-up guidance**, or **add your own templates** (custom name + sections + guidance) in Settings.
- **Context-Aware Polishing:** Detects the app you're typing in (e.g. Slack, Mail, Xcode) and uses `llama-3.3-70b-versatile` to format dictation appropriately — casual for Slack, formal for Mail, code-friendly for IDEs. Every writing style is **editable**, you can **add your own styles**, and a global default covers unrecognized apps.
- **Meeting Mode:** Captures system audio via CoreAudio **process taps** (no screen-recording permission required) alongside your microphone, producing a timestamped, speaker-labeled (**You** / _Them_) transcript.
- **Meeting Summaries:** When a meeting ends, an AI summary (TL;DR, decisions, action items) is appended to the notes automatically, and a notification lets you click straight into the file.
- **Template-Aware Follow-ups:** Draft a follow-up from any meeting note — shaped by the meeting type (a customer call becomes a client email; an interview becomes an internal debrief; a standup becomes a status note). The drafting guidance for each template — recipient, tone, what to include — is **fully editable** in Settings. Opens in the in-app editor to tweak, copy, or save.
- **Auto-Tagging & Entities:** After summarizing, GhostWriter extracts 3–6 topic tags **plus the named entities the meeting is about** — attendees, customer/client, and project — and writes them into the note's YAML front-matter: mirrored into `tags:` for instant Obsidian/Notion graph links, and as structured `attendees:` / `customer:` / `project:` fields for Dataview-style filtering. On by default. Person names are only harvested when redaction is off, so a privacy-conscious setup never captures them.
- **Live Meeting Assistant:** An opt-in floating brief that rides along while a meeting runs — a rolling TL;DR and the open action items so far, refreshed as the conversation develops (cost-aware: only re-briefs on meaningful new dialogue, and never runs in Local-only mode). **Ask** a grounded question about the meeting so far and get an answer from the live transcript. Click the header to collapse it to a minimal strip, clear the Q&A, or hide it entirely and reopen from the menu. On by default when you're set up for cloud transcription.
- **Agendas, Static & Dynamic:** Type an optional agenda when you start a meeting (comma-separated). The Live Brief panel shows a **coverage checklist** — and *also surfaces topics the meeting itself raised* that you didn't list (marked with a ✨), so the agenda builds itself even when you start with a blank one. You stay in control of completion: items are ticked **by tapping** (the model surfaces topics but never auto-marks them done, so nothing flips green on you); tap a discovered topic's **✕** to dismiss it as noise (it won't come back or reach the notes). The final agenda — planned items and kept discovered ones, each checked or not — is written into the notes as its own **`# Agenda`** checklist.
- **Ask Before It Ends:** When you deliberately end a meeting, GhostWriter checks the agenda and — if anything's still unticked (agenda items or discovered topics you haven't marked done) — offers **Keep Recording / End Anyway** with the list, so nothing important slips through. Reuses the live panel's state when it's running (no extra call); otherwise a one-shot check. Cloud-only and best-effort; skipped for very short meetings and in Local-only mode.
- **Cost Controls:** A **Lightweight-tasks model** setting routes high-frequency background work (live brief, agenda coverage, auto-tagging, search-term expansion) to a cheaper/faster model (`llama-3.1-8b-instant` by default) while summaries, follow-ups, and Ask stay on the polishing model. Set an optional **monthly budget** and GhostWriter tracks month-to-date spend, shows a progress bar, flags `⚠️ over budget` in the menu, and notifies once when you cross it — a soft cap that never blocks transcription.
- **In-App Notes Viewer/Editor:** Open any note in a built-in Markdown editor with the **native find bar** (**⌘F**, plus ⌘G / ⇧⌘G to step matches) — just like TextEdit. Notes open **read-only** by default (find works, so you can search safely without touching the text); click **Unlock** to edit, which also enables **find & replace**. Then edit and save, **export to a formatted PDF**, or jump out via "Open in Default App" / "Reveal in Finder". Reachable from the menu, the Notes Assistant, and search/ask results.
- **Local-Only Mode:** A hard privacy switch — transcribe entirely on-device and skip every cloud step (no polishing, summaries, tags, or follow-ups, and no API cost). Nothing leaves the Mac.
- **Auto-Redaction:** Optionally scrub emails, phone numbers, and long number sequences from transcripts before they're typed, saved, or sent to the LLM — replaced with `[redacted …]` labels.
- **Usage & Cost Estimate:** Local counters track audio transcribed and LLM tokens, with a running Groq spend estimate (editable prices) — all-time and month-to-date — in Settings and at a glance in the menu, plus an optional monthly budget with warnings.
- **Error Surfacing & Diagnostics:** Failures post a notification, show a dismissable banner in the menu, and collect in a Diagnostics pane — no more silent gaps.
- **Meeting History & Dictation Recall:** Browse past meetings from the menu bar or the Notes Assistant; ⌃⌥V re-types your last dictation (great when you dictated into the wrong field).
- **Per-Site Browser Styling:** Reads the active browser tab's address (Safari + Chromium; opt-in, Automation permission) so a website gets its own writing style — e.g. Gmail uses Email, GitHub uses Code — via editable `host: style` rules.
- **Dictation Archive:** Optionally save every dictation to its own Markdown file with metadata front-matter (app, host, style, duration, words), organized into dated subfolders (its own layout, independent of meetings). Browse and search them from the menu bar → **Dictations…** — a day-grouped table showing app, style, and duration at a glance.
- **Custom Vocabulary & Replacements:** Feed Whisper your names, acronyms, and jargon, plus post-transcription find→replace rules — domain terms transcribe correctly.
- **Offline Fallback:** If Groq is unreachable, transcription falls back to Apple's on-device speech recognition — dictation keeps working with zero network.
- **Retry Queue:** Meeting segments that fail to transcribe (network blips) are retried automatically with backoff; anything unrecoverable becomes a visible `⚠️ transcription failed` marker in the notes instead of a silent gap.
- **Notes Assistant:** One window with four tools, all grouped by meeting and opening notes in the in-app viewer. **All Notes** browses your full history day-by-day as a table with each meeting's time and duration. **Search** transcripts (debounced, background, scans the 200 most recent meetings) — toggle between **Text** (exact keywords) and **Meaning** (on-device semantic search: find notes by what they're about even without the exact words, powered by Apple's local `NLEmbedding` — free, private, no network; falls back to text search when no OS embedding model is available). **Ask** a single meeting — or **All meetings**: relevant excerpts are retrieved across your whole archive (semantically when available, keyword otherwise), and the answer cites which meeting each point came from, with the source files listed under the answer. **Action Items** aggregates the last 10 meetings with owner/due pills and one-click export to Apple Reminders.
- **Catalog:** A lightweight CRM-style organiser that sits *beside* your notes without touching them — a graph of the **organisations, people, projects, opportunities and tags** your meetings are about. Open it from the menu (**Catalog…**). A three-column browser (sections → list → editor) plus a **Map** tab that renders the whole thing as one searchable tree — `Org → Project → Opportunity → Note → {People, Tags}` — with **Expand-all / Collapse-all** controls and auto-expand while filtering. Organisations form an **unlimited hierarchy** (each with an editable relationship: Root / Customer / Prospect / Partner / Internal / Other); projects belong to orgs, and opportunities to projects. **Notes are assigned to an opportunity *or* an organisation** (mutually exclusive), and the project → org chain is **inherited automatically**. **People and tags are set per note** — each note owns its own set, picked or created inline like tags (people are independent of orgs; an org's people are simply whoever appears on its notes). **Import notes** pulls in your meeting files (`Meeting_*.md` only); each note's editor manages its people, tags (with suggestions promoted from the note's own front-matter — a note token can be turned into any entity), and its **action items** (tick + export to Reminders, individually or all at once). Filter and search notes from the toolbar — **Text**, on-device **Meaning** (semantic), and **Ask** (a cloud Q&A scoped to the filtered notes, with cited sources that open in the editor) — plus one-tap **Unassigned** and **Missing** (file gone from disk) filters. Note rows expose inline **reveal / remove** actions, and the footer offers **Import / reload** and **clean-up** for entries whose Markdown file was deleted (files are never touched). **Quick add** builds a whole org → project → opportunity → people → tags chain (with a parent) in one sheet. Stored as a single `Catalog.json` in the notes folder — rebuildable, backup-friendly, with a **Purge** action that clears the catalog while leaving your note files intact.
- **Usage Stats:** Local-only counters — dictations, words typed, meetings recorded, meeting time, plus a Groq cost estimate — shown at the top of the menu and in Settings → Usage & Cost.
- **Echo Suppression:** When you're on the built-in speaker instead of headphones, half-duplex gating stops the remote party's voice (picked up by your mic as echo) from being mislabeled as "You".
- **Voice Diarization (experimental):** Label distinct remote voices (Them / Them 2 / Them 3) by fingerprinting each segment's voice — pitch via autocorrelation plus timbre — and clustering, fully on-device. **Rename Speakers…** gives them real names per meeting: the notes file is rewritten, and a live meeting keeps using the new names.
- **Action Items as First-Class Tasks:** End-of-meeting summaries emit structured task lists (`- [ ] <action> — @owner (due: date)`); the Notes Assistant shows them as clickable checkboxes with **owner** and **due-date** pills — marking one done writes `- [x]` back into the notes file. Push open items to **Apple Reminders** individually or all at once, with the due date carried over.
- **Organized Notes:** Meeting files are filed into dated subfolders — `Notes/2026/2026-07/03/` by default; switch to year/month, year, or a single flat folder in Settings. History, search, and stats find files in any layout.
- **Global Shortcuts:** Push-to-talk dictation (hold Right Option), Esc to cancel a dictation, ⌃⌥M to toggle Meeting Mode, ⌃⌥P to pause/resume transcription, ⌃⌥N to open the notes — all system-wide, from any app.
- **Native macOS Integration:** Built entirely in Swift. CoreGraphics event taps for global hotkeys, Accessibility (`AXUIElement`) for text injection.
- **Settings Window:** A System Settings-style sidebar UI — configurable AI models, push-to-talk key, meeting overlay mode, speech-detection thresholds, notes folder, and speaker labels. Everything persists and applies live.
- **Guided Permissions:** A live permission-status panel and menu items to authorize Microphone, System Audio Recording, and Accessibility, plus a one-click **Reset All Permissions** that clears the TCC grants and relaunches for a clean re-prompt.
- **Secure Key Management:** Your API key is verified against the Groq API at setup and stored in the macOS Keychain — never on disk in plain text.

## 🚀 Installation

Because GhostWriter relies on global hotkeys, accessibility, and system-audio capture, it must be packaged and code-signed cleanly so macOS attributes permissions to the app itself (not your terminal).

A build-and-deploy script is provided:

1. Clone this repository to your Mac.
2. Run the ship script:
   ```bash
   ./ship.sh
   ```
3. The script compiles the Swift binary, bundles it as `GhostWriter.app` with an icon, code-signs it, installs it in-place to `/Applications`, and produces a redistributable `.release/GhostWriter.zip`.
4. It then launches the app automatically.

> **Note:** `ship.sh` performs an *in-place* update of an existing `/Applications/GhostWriter.app` so your previously granted permissions (which macOS keys to the app's signing identity) are preserved across rebuilds.

## ⚙️ Setup & Usage

### First launch
1. **API Key:** GhostWriter prompts for a [Groq API Key](https://console.groq.com/keys) — enter your key starting with `gsk_`. The key is verified live against the Groq API before saving and stored in the macOS Keychain (change it later in Settings → General).
2. **Permissions:** macOS presents native prompts for **Microphone**, **System Audio Recording**, and **Accessibility**. Grant all three. (Accessibility must be toggled on in System Settings — that's a macOS requirement; the app detects the grant and starts the hotkey without needing a relaunch.)

### Dictation
1. Place your cursor in any text field, in any app.
2. Press and hold the push-to-talk key (**Right Option** by default, configurable in Settings) — a glowing indicator appears.
3. Speak naturally.
4. Release the key. GhostWriter transcribes, polishes, and types the result at your cursor.

### Meeting Mode
1. Choose **Start Meeting** in the menu (or press **⌃⌥M**) — a dialog asks what kind of meeting it is (**template**: Customer Call by default, plus Standup, 1:1, Interview, Planning, Retrospective, Lecture, Brainstorm, General, and any custom templates you've added), which shapes what the summary extracts, lets you type an optional **agenda** (comma-separated) that drives the live coverage checklist and the end-of-meeting check, and offers a **Show live brief** switch — a per-meeting toggle that defaults to your global setting, so you can turn the floating brief on or off for just this call (disabled when it couldn't run anyway, i.e. Local-only mode or no API key). When a conferencing app or browser call starts using your mic, GhostWriter offers to start on its own.
2. GhostWriter listens to both your mic and the system audio and writes a live Markdown transcript, tagging each line as **You** or _Them_ (labels customizable; **Rename Speakers…** gives voices real names per meeting).
3. A small pill overlay indicates recording is active — switch it to live captions or hide it entirely in Settings.
4. The menu-bar icon shows the elapsed recording time while a meeting is running (dictation shows a 🎤 timer, quick notes a 📝 timer).
5. Choose **End Meeting** to stop — GhostWriter first runs a quick coverage check and, if anything's still open, offers **Keep Recording / End Anyway**; when the call's mic is released it offers to stop for you. The last in-flight segments are flushed and transcribed before the file is finalized, the template's AI summary and an **Agenda** checklist are appended (toggleable, and skipped automatically when a short call has too little dialogue), and a notification links to the file.

### Quick Notes
Press **⌃⌥J** anywhere to dictate a thought — press again to save, Esc to discard. The note is transcribed, lightly polished, and timestamped into one file per day (`QuickNotes_2026-07-05.md`) in a dedicated Quick Notes folder, with an optional "saved" notification that opens the file. Kept apart from meeting notes so history and the Notes Assistant stay meetings-only.

> **Bluetooth headsets (AirPods):** using a Bluetooth microphone forces AirPods from the high-quality A2DP profile into the HFP call profile — output quality drops and volume shifts (all conferencing apps have this). GhostWriter uses the system default input, and fully releases the mic after each use so AirPods return to full quality immediately. If the profile switch bothers you, enable **"Prefer built-in microphone"** (Settings → General) to capture from the Mac's built-in mic instead — AirPods then stay in full quality throughout.

### Menu bar
Organized act → find → configure; the header shows the version and quick stats (meetings this week, total dictations).
- **Start Meeting** (⌃⌥M) — becomes **End Meeting** while recording; **Pause Meeting** (⌃⌥P) and **Show / Hide Live Brief** appear only mid-meeting (pause writes *paused/resumed* markers; the Live Brief toggle shows or hides the floating in-meeting assistant without stopping it).
- **Quick Note** (⌃⌥J) — toggle-dictate into today's quick-notes file.
- **Notes ▸** — open the current/latest meeting notes (⌃⌥N), today's quick notes, the last 5 meetings grouped by day, **Browse All Notes…**, **Rename Speakers…**, and the notes folder.
- **Notes Assistant…** — opens on **All Notes**, plus search transcripts, ask questions about one meeting or across all of them (with cited sources), and review action items grouped by meeting (with owner/due pills and export to Reminders).
- **Dictations…** — a searchable, day-grouped browser of your archived dictations; click any to open in the in-app editor.
- **Catalog…** — organise notes into a graph of organisations, people, projects, opportunities and tags; browse by section or the Map tree, filter/search/Ask, and Quick-add a whole chain.
- **Settings…** — everything else lives here, including the API key (General) and permissions (Privacy & Security).

(⌃⌥V re-types your most recent dictation from anywhere — no menu needed.)

### Global shortcuts
These work system-wide, from any app (they ride the same Accessibility event tap as the push-to-talk key):

| Shortcut | Action |
| --- | --- |
| Hold **Right Option** (configurable) | Push-to-talk dictation |
| **Esc** (while dictating) | Cancel the recording — nothing is typed |
| **⌃⌥V** | Type the most recent dictation again |
| **⌃⌥J** | Quick note — dictate into today's notes file (press again to save, Esc to cancel) |
| **⌃⌥M** | Start / stop Meeting Mode |
| **⌃⌥P** | Pause / resume meeting transcription |
| **⌃⌥N** | Open meeting notes |

### Settings
A System Settings-style sidebar, grouped into **Capture**, **Meetings**, and **App**:

| Group / Pane | Options (defaults in bold) |
| --- | --- |
| **General** | API key status; transcription model (**whisper-large-v3**); transcription language (**en**, ISO 639-1 — applies to dictation *and* meetings); polishing model (**llama-3.3-70b-versatile**); lightweight-tasks model (**llama-3.1-8b-instant** — cheap/fast model for the live brief, agenda coverage, auto-tagging, and search-term expansion); prefer built-in microphone (**off** — uses the system default input; turn on to keep AirPods in high-quality audio); offline fallback (**on** — Apple on-device recognition when Groq is unreachable, covering dictation, quick notes, and meetings); date format for the menu & Notes Assistant (**dd MMM yyyy** → 03 Jul 2026; presets + custom pattern with live preview); start at login (**off** — registers as a macOS Login Item); reset all settings |
| Capture · **Dictation** | Push-to-talk key (**Right Option**, or Left Option / Right Command / Right Control / Fn); streaming dictation (**on**, chunk **10 s**); accuracy — custom vocabulary + find→replace rules; recall — keep recent dictations for ⌃⌥V (**on**, keep **20**); archive — save each dictation to a file (**on**) with its own folder and organization (**year/month**) |
| Capture · **Writing Styles** | Voice commands (**on**, editable rule list); writing styles (6 editable built-ins + your own custom styles, with a global default for unrecognized apps); per-app style overrides; browser tab styles (**on** — per-site `host: style` rules, e.g. Gmail → Email) |
| Capture · **Quick Notes** | Save-to folder (**…/Notes/Quick Notes**); saved notification (**on**) |
| Meetings · **Recording** | Call detection — offer to start/stop with the call (**on**); overlay mode (**minimal pill** / live captions / hidden); caption fade delay (**6 s**); echo suppression (**on**, gate **0.4 s**); speakers — labels (**You** / **Them**) and voice diarization (**on**, experimental; max speakers **4**); *Advanced (collapsed):* mic threshold (**−40 dBFS**), system-audio threshold (**−50 dBFS**), segment flush pause (**1.5 s**), max segment length (**25 s**), retry attempts (**3**), retry interval (**20 s**) |
| Meetings · **Notes & Summaries** | Notes folder (**~/Documents/Notes**); file organization (**year/month/day** / year/month / year / single folder); Obsidian front-matter (**on**); meeting template (**Customer Call**, 9 built-in types + your own custom templates — editable summary sections *and* follow-up guidance, add/rename/delete); AI summary (**on**); action items (**on**); auto-tag topics + entities into front-matter (**on**); live brief during meetings (**on** — floating in-meeting assistant, cloud-only; this is the default for the per-meeting **Show live brief** switch in the start dialog); saved notification (**on**); Assistant search depth (**200** recent meetings); action items from last (**10** meetings) |
| Privacy & Security · **Privacy** | Local-only mode (**off** — on-device only, no network); redact sensitive info (**off**) with per-category toggles for emails, phones, and long number sequences |
| Privacy & Security · **Permissions** | Live status of Microphone, System Audio Recording, Accessibility, Automation (default browser, optional), and Reminders (action-item export, optional) with shortcuts to the relevant Settings panes, plus Reset All Permissions |
| App · **Shortcuts** | Reference card of all global shortcuts (push-to-talk, Esc, ⌃⌥V, ⌃⌥J, ⌃⌥M / ⌃⌥P / ⌃⌥N) |
| App · **Usage & Cost** | Local usage counters — dictations, words, meetings, time — plus an editable-price Groq **cost estimate** (month-to-date and all-time, audio transcribed, LLM tokens), an optional **monthly budget** (0 = off) with a spend bar and over-budget warning, all with their own reset |
| App · **Diagnostics** | Error notifications toggle (**on**) and a list of recent failures with a clear button |
| App · **About** | Version and build, description, privacy note |

All values are stored in `UserDefaults` (start-at-login lives in macOS Login Items) and take effect immediately — model and hotkey changes apply to the very next request/keypress, no restart needed. Every control has a per-item reset, plus a global "Reset All Settings".

## 🛠 Tech Stack & Architecture

- **Language:** Swift (macOS **14.2+** — required for CoreAudio process taps)
- **Dictation audio:** `AVFoundation` — 16 kHz PCM capture with RMS-based Voice Activity Detection.
- **System audio:** CoreAudio process taps — `CATapDescription` → `AudioHardwareCreateProcessTap` → aggregate device → direct `AudioDeviceIOProc` callback, converted to 16 kHz mono via `AVAudioConverter`. Uses only the **System Audio Recording** permission (`NSAudioCaptureUsageDescription`), not Screen Recording.
- **Input/Output:** `CoreGraphics` CGEvent taps for the global hotkey; `ApplicationServices` `AXUIElement` API for text injection.
- **UI:** SwiftUI for the API-key onboarding and the floating recording indicator.
- **AI backend:** REST calls to Groq's Whisper (`whisper-large-v3`) and Llama (`llama-3.3-70b-versatile`) models.
- **Logging:** unified `os.Logger` with per-feature categories. Rare lifecycle events at info, errors/warnings always persisted, high-frequency events at debug (transcript content is privacy-redacted). Inspect with:
  ```bash
  log stream --predicate 'subsystem BEGINSWITH "com.ghostwriter"' --level debug
  ```

## 📁 Project Layout

| Path | Purpose |
| --- | --- |
| `Sources/Services/HotkeyManager.swift` | Global hotkeys (push-to-talk, Esc, ⌃⌥ shortcuts) via CGEvent tap |
| `Sources/Audio/AudioCapture.swift` | Microphone capture + VAD |
| `Sources/Audio/SystemAudioCapture.swift` | System-audio capture via CoreAudio process taps |
| `Sources/Transcription/GroqService.swift` | Groq transcription + polishing API client |
| `Sources/Meetings/TextPolisher.swift` / `AppDetector.swift` | Context-aware formatting |
| `Sources/Services/TextInjector.swift` | Accessibility-based text injection |
| `Sources/Meetings/MeetingNotesWriter.swift` | Markdown transcript writer (front-matter, summaries, dated subfolders) |
| `Sources/Audio/SpeakerProfiler.swift` | Voice-fingerprint clustering for speaker diarization |
| `Sources/Meetings/MeetingDetector.swift` | Per-process mic inspection — call start/end detection |
| `Sources/Views/RenameSpeakersWindow.swift` | Per-meeting speaker renaming |
| `Sources/Transcription/OfflineTranscriber.swift` | On-device speech fallback (Apple Speech) |
| `Sources/Services/NotificationManager.swift` | Post-meeting, quick-note, and error notifications |
| `Sources/Meetings/NotesAssistant.swift` | `NotesLibrary` — shared notes data layer (file listing, text/semantic search, cross-meeting excerpts, action-item parsing) |
| `Sources/Transcription/SemanticIndex.swift` | On-device semantic search over notes (Apple `NLEmbedding`, cached) |
| `Sources/Meetings/LiveMeetingAssistant.swift` | Floating in-meeting brief + grounded Ask (rolling TL;DR / actions) |
| `Sources/Views/NotesViewerWindow.swift` | In-app Markdown viewer/editor (find bar, read-only/unlock-to-edit, follow-up, rename, PDF export, open externally) |
| `Sources/Models/Catalog.swift` | Catalog model + `CatalogStore` (Codable `Catalog.json` store: orgs/projects/opportunities plus per-note people/tags, org hierarchy, project→org inheritance, import, missing-file reconcile, purge) |
| `Sources/Catalog/CatalogWindow.swift` | Catalog window — three-column browser, Map tree (per-note people/tags, expand/collapse), note linking, toolbar search (Text/Meaning/Ask) + Unassigned/Missing filters, row actions, Quick add |
| `Sources/Utils/MarkdownPDF.swift` | Paginated Markdown → PDF renderer (CoreText) |
| `Sources/Services/RemindersExporter.swift` | Export action items to Apple Reminders (EventKit) |
| `Sources/Views/DictationsWindow.swift` | Searchable, day-grouped browser for archived dictations |
| `Sources/Services/Redactor.swift` | Opt-in redaction of emails / phones / long numbers |
| `Sources/Utils/Diagnostics.swift` | In-memory recent-errors log for the Diagnostics pane |
| `Sources/Models/UsageStats.swift` | Local usage counters + Groq cost estimate |
| `Sources/Services/PermissionGuard.swift` | Mic / Accessibility / System-audio permission handling |
| `Sources/Models/AppSettings.swift` | UserDefaults-backed settings store with defaults |
| `Sources/Utils/Log.swift` | os.Logger categories (visible in Console.app) |
| `Sources/Views/SettingsView.swift` | Sidebar-style settings window (SwiftUI) |
| `Sources/App/GhostWriterApp.swift` | Menu-bar app, meeting mode, permission flow |
| `ship.sh` | Build, bundle, sign, and install to `/Applications` |
| `make_icon.swift` | Generates the app icon (`GhostWriter.icns`) |

## 🔐 Permissions Explained

| Permission | Why it's needed |
| --- | --- |
| **Microphone** | Capture your speech for dictation and your side of meetings. |
| **System Audio Recording** | Capture the other participants' audio in Meeting Mode (via process taps). |
| **Accessibility** | Detect the Right Option hotkey globally and inject text at your cursor. |
| **Automation** (optional) | Read the active browser tab's address for per-site dictation styling (Safari + Chromium browsers). Prompted only on first use, per browser; decline and browser dictation just uses the generic Browser style. |
| **Reminders** (optional) | Export meeting action items to the Reminders app (Notes Assistant → Action Items). Prompted only on first export; decline and the rest of the app is unaffected. |

macOS keys each grant to the app's code signature, so re-signing with a different identity resets them. If a permission gets stuck, use **Reset All Permissions…** from the menu (it also clears the Automation and Reminders grants).

---
*Built natively for Apple Silicon and macOS.*
