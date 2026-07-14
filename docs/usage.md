# 🚀 Installation, Setup & Usage

[← Back to README](../README.md) · [Features](features.md) · [Settings](settings.md) · [Architecture](architecture.md)

## Installation

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

## Setup & Usage

### First launch
1. **API Key:** GhostWriter prompts for a [Groq API Key](https://console.groq.com/keys) — enter your key starting with `gsk_`. The key is verified live against the Groq API before saving and stored in the macOS Keychain (change it later in Settings → General).
2. **Permissions:** macOS presents native prompts for **Microphone**, **System Audio Recording**, and **Accessibility**. Grant all three. (Accessibility must be toggled on in System Settings — that's a macOS requirement; the app detects the grant and starts the hotkey without needing a relaunch.)

### Dictation
1. Place your cursor in any text field, in any app.
2. Press and hold the push-to-talk key (**Right Option** by default, configurable in Settings) — a glowing indicator appears.
3. Speak naturally.
4. Release the key. GhostWriter transcribes, polishes, and types the result at your cursor.

### Meeting Mode
1. Choose **Start Meeting** in the menu (or press **⌃⌥M**) — a dialog asks what kind of meeting it is (**template**: Customer Call by default, plus Discovery Call, Solution Demo, Solution Scoping, Project Kickoff, Planning, Standup, 1:1, All-Hands, Brainstorm, Lecture / Webinar, and General, grouped into categories, plus any custom templates you've added), which shapes what the summary extracts, lets you optionally **link** the note to an organisation or opportunity (with a search box that narrows the list as your Catalog grows, plus quick-add entries), lets you type an optional **agenda** (comma-separated) that drives the live coverage checklist and the end-of-meeting check, and offers a **Show live brief** switch — a per-meeting toggle that defaults to your global setting, so you can turn the floating brief on or off for just this call (disabled when it couldn't run anyway, i.e. Local-only mode or no API key). When a conferencing app or browser call starts using your mic, GhostWriter offers to start on its own.
2. GhostWriter listens to both your mic and the system audio and writes a live Markdown transcript, tagging each line as **You** or _Them_ (labels customizable; **Rename Speakers…** gives voices real names per meeting).
3. A small pill overlay indicates recording is active — switch it to live captions or hide it entirely in Settings.
4. The menu-bar icon shows the elapsed recording time while a meeting is running (dictation shows a 🎤 timer, quick notes a 📝 timer).
5. Choose **End Meeting** to stop — GhostWriter first runs a quick coverage check and, if anything's still open, offers **Keep Recording / End Anyway**; when the call's mic is released it offers to stop for you. The last in-flight segments are flushed and transcribed before the file is finalized, the template's AI summary and an **Agenda** checklist are appended (toggleable, and skipped automatically when a short call has too little dialogue), and a notification links to the file.

### Quick Notes
Press **⌃⌥J** anywhere to dictate a thought — press again to save, Esc to discard. The note is transcribed, lightly polished, and timestamped into one file per day (`QuickNotes_2026-07-05.md`) in a dedicated Quick Notes folder, with an optional "saved" notification that opens the file. Kept apart from meeting notes so history and Ask Your Notes stay meetings-only.

> **Bluetooth headsets (AirPods):** using a Bluetooth microphone forces AirPods from the high-quality A2DP profile into the HFP call profile — output quality drops and volume shifts (all conferencing apps have this). GhostWriter uses the system default input, and fully releases the mic after each use so AirPods return to full quality immediately. If the profile switch bothers you, enable **"Prefer built-in microphone"** (Settings → General) to capture from the Mac's built-in mic instead — AirPods then stay in full quality throughout.

### Menu bar
Organized act → find → configure; the header shows the version and quick stats (meetings this week, total dictations).
- **Start Meeting** (⌃⌥M) — becomes **End Meeting** while recording; **Pause Meeting** (⌃⌥P) and the **Live Brief** controls appear only mid-meeting (pause writes *paused/resumed* markers). The Live Brief menu item adapts: **Start Live Brief** if the meeting began without it, **Hide / Show Live Brief** while it's running, or **Resume Live Brief** after you've turned it off — so you can bring the brief up at any point, even mid-meeting. A separate **Turn Off Live Brief** stops its AI updates entirely for the rest of the meeting (no more token spend); the panel's own ✕ only hides it.
- **Quick Note** (⌃⌥J) — toggle-dictate into today's quick-notes file.
- **Notes & History ▸** — open the current/latest meeting notes (⌃⌥N), today's quick notes, the last 5 meetings grouped by day, **Rename Speakers…**, and the notes folder. (Full browsing and search live in the **Catalog**'s Notes section.) In the note viewer, the **Draft…** menu leads with a one-click **Follow-Up Packet** — a follow-up email, updated POC plan, and action items in a single document, exportable as one PDF (configure its sections in Settings → Meetings → Draft Templates).
- **Today's Digest…** — a scheduled or on-demand rollup, grouped by relationship, of recent meetings, open/overdue action items (with export to Reminders), and quiet relationships.
- **Ask Your Notes…** — a multi-turn chat grounded in your archive: pick a scope (all meetings, a chosen set, or an org/opportunity) and ask questions; answers cite the meetings each point came from.
- **Dictations…** — a searchable, day-grouped browser of your archived dictations; click any to open in the in-app editor, or **Reload** to re-scan (deleted files drop off).
- **Catalog…** — organise notes into a graph of organisations, people, projects, opportunities and tags; browse by section or the Map tree, filter/search/Ask, and Quick-add a whole chain. Opens on a **Dashboard** (Overview section) built for sales engineers — POC command center, a **meeting-type mix** funnel (Discovery → Demo → Scoping → Kickoff) showing where accounts sit in the technical cycle, open technical questions, action items, competitive/product signals, engagement trend, and quiet accounts — all filterable by time range (Today through All time) and account. Also home (Tools section) to the **POC Tracker** — pick an opportunity and track its proof-of-concept success criteria, added by hand or **Suggest from meetings**, cycling each Pending → Passed → Failed — and **Keyword Radar**, a cross-meeting rollup of your watchlist hits (each term's total mentions, meetings, and last-seen, ranked, click-through to the source meetings).
- **Settings…** — everything else lives here, including the API key (General) and permissions (Privacy & Security).

(⌃⌥V re-types your most recent dictation from anywhere — no menu needed.)

## Global shortcuts
These work system-wide, from any app (they ride the same Accessibility event tap as the push-to-talk key):

| Shortcut | Action |
| --- | --- |
| Hold **Right Option** (configurable) | Push-to-talk dictation |
| **Esc** (while dictating) | Cancel the recording — nothing is typed |
| **⌃⌥V** | Type the most recent dictation again |
| **⌃⌥J** | Quick note — dictate into today's notes file (press again to save, Esc to cancel) |
| **⌃⌥M** | Start / stop Meeting Mode |
| **⌃⌥P** | Pause / resume meeting transcription |
| **⌃⌥B** | Bookmark the current moment in a running meeting |
| **⌃⌥N** | Open meeting notes |
