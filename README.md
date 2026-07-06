# 👻 GhostWriter

> A zero-latency, context-aware macOS dictation agent that magically types polished text into any active window — and now transcribes your meetings.

GhostWriter is a lightweight native macOS utility that lives in your menu bar. Hold down the **Right Option** key to speak, and GhostWriter instantly transcribes and polishes your speech using Groq's ultra-fast Whisper and Llama models, injecting the perfect text directly into whatever app you're currently using.

It also has a **Meeting Mode** that captures both sides of a conversation — your microphone *and* the system audio (the other participants) — and writes a live, speaker-attributed transcript to a Markdown notes file.

## ✨ Features

- **Zero-Latency Dictation:** Powered by Groq's `whisper-large-v3` for near-instant speech-to-text. Long dictations stream — chunks are transcribed while you're still speaking, so releasing the key types almost instantly.
- **Voice Commands:** Say "new paragraph", spoken punctuation ("comma", "question mark"), "scratch that", or "all caps … end caps" while dictating — the rule list is editable in Settings.
- **Call Detection:** When Zoom, Teams, Webex, Slack, or a browser call (Google Meet) starts using your microphone, GhostWriter offers to start Meeting Mode — and offers to stop and save the notes when the call ends.
- **Quick Notes (⌃⌥J):** Toggle-dictate a thought from anywhere into a per-day notes file — transcribed, polished, timestamped, with click-to-open notifications.
- **Meeting Templates:** Nine built-in meeting types (Customer Call, Standup, 1:1, Interview, Planning, Retrospective, Lecture, Brainstorm, General) each extract their own summary sections — chosen right in the start-meeting dialog. Edit any template's sections, or **add your own templates** (custom name + sections) in Settings.
- **Context-Aware Polishing:** Detects the app you're typing in (e.g. Slack, Mail, Xcode) and uses `llama-3.3-70b-versatile` to format dictation appropriately — casual for Slack, formal for Mail, code-friendly for IDEs. Every writing style is **editable**, you can **add your own styles**, and a global default covers unrecognized apps.
- **Meeting Mode:** Captures system audio via CoreAudio **process taps** (no screen-recording permission required) alongside your microphone, producing a timestamped, speaker-labeled (**You** / _Them_) transcript.
- **Meeting Summaries:** When a meeting ends, an AI summary (TL;DR, decisions, action items) is appended to the notes automatically, and a notification lets you click straight into the file.
- **Template-Aware Follow-ups:** Draft a follow-up from any meeting note — shaped by the meeting type (a customer call becomes a client email; an interview becomes an internal debrief; a standup becomes a status note). Opens in the in-app editor to tweak, copy, or save.
- **Auto-Tagging:** After summarizing, 3–6 topic tags are extracted and merged into the note's YAML front-matter — instant Obsidian/Notion graph links. On by default (needs front-matter).
- **In-App Notes Viewer/Editor:** Open any note in a built-in Markdown editor — edit and save, or jump out via "Open in Default App" / "Reveal in Finder". Reachable from the menu, the Notes Assistant, and search/ask results.
- **Local-Only Mode:** A hard privacy switch — transcribe entirely on-device and skip every cloud step (no polishing, summaries, tags, or follow-ups, and no API cost). Nothing leaves the Mac.
- **Auto-Redaction:** Optionally scrub emails, phone numbers, and long number sequences from transcripts before they're typed, saved, or sent to the LLM — replaced with `[redacted …]` labels.
- **Usage & Cost Estimate:** Local counters track audio transcribed and LLM tokens, with a running Groq spend estimate (editable prices) in Settings and at a glance in the menu.
- **Error Surfacing & Diagnostics:** Failures post a notification, show a dismissable banner in the menu, and collect in a Diagnostics pane — no more silent gaps.
- **Meeting History & Dictation Recall:** Browse past meetings from the menu bar or the Notes Assistant; ⌃⌥V re-types your last dictation (great when you dictated into the wrong field).
- **Per-Site Browser Styling:** Reads the active browser tab's address (Safari + Chromium; opt-in, Automation permission) so a website gets its own writing style — e.g. Gmail uses Email, GitHub uses Code — via editable `host: style` rules.
- **Dictation Log:** A persisted record of recent dictations — which app (and browser host), which writing style, and duration — in Settings → Usage & Cost, with a clear button. Great for tuning your per-app and per-site style rules.
- **Dictation Archive:** Optionally save every dictation to its own Markdown file with metadata front-matter (app, host, style, duration, words), organized into dated subfolders (its own layout, independent of meetings). Browse and search them from the menu bar → **Dictations…**.
- **Custom Vocabulary & Replacements:** Feed Whisper your names, acronyms, and jargon, plus post-transcription find→replace rules — domain terms transcribe correctly.
- **Offline Fallback:** If Groq is unreachable, transcription falls back to Apple's on-device speech recognition — dictation keeps working with zero network.
- **Retry Queue:** Meeting segments that fail to transcribe (network blips) are retried automatically with backoff; anything unrecoverable becomes a visible `⚠️ transcription failed` marker in the notes instead of a silent gap.
- **Notes Assistant:** One window with four tools, all grouped by meeting and opening notes in the in-app viewer. **All Notes** browses your full history day-by-day. **Search** transcripts (debounced, background, scans the 200 most recent meetings). **Ask** a single meeting — or **All meetings**: the question is expanded into search terms, matching excerpts are retrieved across your whole archive, and the answer cites which meeting each point came from, with the source files listed under the answer. **Action Items** aggregates the last 10 meetings.
- **Usage Stats:** Local-only counters — dictations, words typed, meetings recorded, meeting time, plus a Groq cost estimate — shown at the top of the menu and in Settings → Usage & Cost.
- **Echo Suppression:** When you're on the built-in speaker instead of headphones, half-duplex gating stops the remote party's voice (picked up by your mic as echo) from being mislabeled as "You".
- **Voice Diarization (experimental):** Label distinct remote voices (Them / Them 2 / Them 3) by fingerprinting each segment's voice — pitch via autocorrelation plus timbre — and clustering, fully on-device. **Rename Speakers…** gives them real names per meeting: the notes file is rewritten, and a live meeting keeps using the new names.
- **Action-Item Checklists:** End-of-meeting summaries emit Markdown task lists (`- [ ]`); the Notes Assistant shows them as clickable checkboxes — marking one done writes `- [x]` back into the notes file itself.
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
1. Choose **Start Meeting** in the menu (or press **⌃⌥M**) — a dialog asks what kind of meeting it is (**template**: Customer Call by default, plus Standup, 1:1, Interview, Planning, Retrospective, Lecture, Brainstorm, General, and any custom templates you've added), which shapes what the summary extracts. When a conferencing app or browser call starts using your mic, GhostWriter offers to start on its own.
2. GhostWriter listens to both your mic and the system audio and writes a live Markdown transcript, tagging each line as **You** or _Them_ (labels customizable; **Rename Speakers…** gives voices real names per meeting).
3. A small pill overlay indicates recording is active — switch it to live captions or hide it entirely in Settings.
4. The menu-bar icon shows the elapsed recording time while a meeting is running (dictation shows a 🎤 timer, quick notes a 📝 timer).
5. Choose **End Meeting** to stop — and when the call's mic is released, GhostWriter offers to stop for you. The last in-flight segments are flushed and transcribed before the file is finalized, the template's AI summary is appended (toggleable, and skipped automatically when a short call has too little dialogue), and a notification links to the file.

### Quick Notes
Press **⌃⌥J** anywhere to dictate a thought — press again to save, Esc to discard. The note is transcribed, lightly polished, and timestamped into one file per day (`QuickNotes_2026-07-05.md`) in a dedicated Quick Notes folder, with an optional "saved" notification that opens the file. Kept apart from meeting notes so history and the Notes Assistant stay meetings-only.

> **Bluetooth headsets (AirPods):** using a Bluetooth microphone forces AirPods from the high-quality A2DP profile into the HFP call profile — output quality drops and volume shifts (all conferencing apps have this). GhostWriter uses the system default input, and fully releases the mic after each use so AirPods return to full quality immediately. If the profile switch bothers you, enable **"Prefer built-in microphone"** (Settings → General) to capture from the Mac's built-in mic instead — AirPods then stay in full quality throughout.

### Menu bar
Organized act → find → configure; the header shows the version and quick stats (meetings this week, total dictations).
- **Start Meeting** (⌃⌥M) — becomes **End Meeting** while recording; **Pause Meeting** (⌃⌥P) appears only mid-meeting (writes *paused/resumed* markers).
- **Quick Note** (⌃⌥J) — toggle-dictate into today's quick-notes file.
- **Notes ▸** — open the current/latest meeting notes (⌃⌥N), today's quick notes, the last 5 meetings grouped by day, **Browse All Notes…**, **Rename Speakers…**, and the notes folder.
- **Notes Assistant…** — opens on **All Notes**, plus search transcripts, ask questions about one meeting or across all of them (with cited sources), and review action items grouped by meeting.
- **Dictations…** — a searchable, day-grouped browser of your archived dictations; click any to open in the in-app editor.
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
| **General** | API key status; transcription model (**whisper-large-v3**); polishing model (**llama-3.3-70b-versatile**); prefer built-in microphone (**off** — uses the system default input; turn on to keep AirPods in high-quality audio); offline fallback (**on** — Apple on-device recognition when Groq is unreachable, covering dictation, quick notes, and meetings); date format for the menu & Notes Assistant (**dd MMM yyyy** → 03 Jul 2026; presets + custom pattern with live preview); start at login (**off** — registers as a macOS Login Item); reset all settings |
| Capture · **Dictation** | Push-to-talk key (**Right Option**, or Left Option / Right Command / Right Control / Fn); streaming dictation (**on**, chunk **10 s**); language (**en**); accuracy — custom vocabulary + find→replace rules; recall — keep recent dictations for ⌃⌥V (**on**, keep **20**); archive — save each dictation to a file (**on**) with its own folder and organization (**year/month**) |
| Capture · **Writing Styles** | Voice commands (**on**, editable rule list); writing styles (6 editable built-ins + your own custom styles, with a global default for unrecognized apps); per-app style overrides; browser tab styles (**on** — per-site `host: style` rules, e.g. Gmail → Email) |
| Capture · **Quick Notes** | Save-to folder (**…/Notes/Quick Notes**); saved notification (**on**) |
| Meetings · **Recording** | Call detection — offer to start/stop with the call (**on**); overlay mode (**minimal pill** / live captions / hidden); caption fade delay (**6 s**); echo suppression (**on**, gate **0.4 s**); *Advanced (collapsed):* mic threshold (**−40 dBFS**), system-audio threshold (**−50 dBFS**), segment flush pause (**1.5 s**), max segment length (**25 s**), retry attempts (**3**), retry interval (**20 s**) |
| Meetings · **Notes & Summaries** | Notes folder (**~/Documents/Notes**); file organization (**year/month/day** / year/month / year / single folder); Obsidian front-matter (**off**); speaker labels (**You** / **Them**); voice diarization (**on**, experimental; max speakers **4**); meeting template (**Customer Call**, 9 built-in types + your own custom templates — editable sections, add/rename/delete); AI summary (**on**); action items (**on**); auto-tag topics into front-matter (**on**); saved notification (**on**); Assistant search depth (**200** recent meetings); action items from last (**10** meetings) |
| Privacy & Security · **Privacy** | Local-only mode (**off** — on-device only, no network); redact sensitive info (**off**) with per-category toggles for emails, phones, and long number sequences |
| Privacy & Security · **Permissions** | Live status of Microphone, System Audio Recording, Accessibility, and Automation (default browser, optional) with shortcuts to the relevant Settings panes, plus Reset All Permissions |
| App · **Shortcuts** | Reference card of all global shortcuts (push-to-talk, Esc, ⌃⌥V, ⌃⌥J, ⌃⌥M / ⌃⌥P / ⌃⌥N) |
| App · **Usage & Cost** | Local usage counters — dictations, words, meetings, time — plus an editable-price Groq **cost estimate** (audio transcribed, LLM tokens); a **Dictation Log** (app/host · style · duration, clearable); with their own reset |
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
| `Sources/HotkeyManager.swift` | Global hotkeys (push-to-talk, Esc, ⌃⌥ shortcuts) via CGEvent tap |
| `Sources/AudioCapture.swift` | Microphone capture + VAD |
| `Sources/SystemAudioCapture.swift` | System-audio capture via CoreAudio process taps |
| `Sources/GroqService.swift` | Groq transcription + polishing API client |
| `Sources/TextPolisher.swift` / `AppDetector.swift` | Context-aware formatting |
| `Sources/TextInjector.swift` | Accessibility-based text injection |
| `Sources/MeetingNotesWriter.swift` | Markdown transcript writer (front-matter, summaries, dated subfolders) |
| `Sources/SpeakerProfiler.swift` | Voice-fingerprint clustering for speaker diarization |
| `Sources/MeetingDetector.swift` | Per-process mic inspection — call start/end detection |
| `Sources/RenameSpeakersWindow.swift` | Per-meeting speaker renaming |
| `Sources/OfflineTranscriber.swift` | On-device speech fallback (Apple Speech) |
| `Sources/NotificationManager.swift` | Post-meeting, quick-note, and error notifications |
| `Sources/NotesAssistant.swift` | All Notes / Search / Ask / Action Items window |
| `Sources/NotesViewerWindow.swift` | In-app Markdown viewer/editor (edit, follow-up, rename, open externally) |
| `Sources/DictationsWindow.swift` | Searchable, day-grouped browser for archived dictations |
| `Sources/Redactor.swift` | Opt-in redaction of emails / phones / long numbers |
| `Sources/Diagnostics.swift` | In-memory recent-errors log for the Diagnostics pane |
| `Sources/UsageStats.swift` | Local usage counters + Groq cost estimate |
| `Sources/PermissionGuard.swift` | Mic / Accessibility / System-audio permission handling |
| `Sources/AppSettings.swift` | UserDefaults-backed settings store with defaults |
| `Sources/Log.swift` | os.Logger categories (visible in Console.app) |
| `Sources/SettingsView.swift` | Sidebar-style settings window (SwiftUI) |
| `Sources/GhostWriterApp.swift` | Menu-bar app, meeting mode, permission flow |
| `ship.sh` | Build, bundle, sign, and install to `/Applications` |
| `make_icon.swift` | Generates the app icon (`GhostWriter.icns`) |

## 🔐 Permissions Explained

| Permission | Why it's needed |
| --- | --- |
| **Microphone** | Capture your speech for dictation and your side of meetings. |
| **System Audio Recording** | Capture the other participants' audio in Meeting Mode (via process taps). |
| **Accessibility** | Detect the Right Option hotkey globally and inject text at your cursor. |
| **Automation** (optional) | Read the active browser tab's address for per-site dictation styling (Safari + Chromium browsers). Prompted only on first use, per browser; decline and browser dictation just uses the generic Browser style. |

macOS keys each grant to the app's code signature, so re-signing with a different identity resets them. If a permission gets stuck, use **Reset All Permissions…** from the menu (it now also clears the Automation grant).

---
*Built natively for Apple Silicon and macOS.*
