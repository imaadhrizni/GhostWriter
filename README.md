# 👻 GhostWriter

> A zero-latency, context-aware macOS dictation agent that magically types polished text into any active window — and now transcribes your meetings.

GhostWriter is a lightweight native macOS utility that lives in your menu bar. Hold down the **Right Option** key to speak, and GhostWriter instantly transcribes and polishes your speech using Groq's ultra-fast Whisper and Llama models, injecting the perfect text directly into whatever app you're currently using.

It also has a **Meeting Mode** that captures both sides of a conversation — your microphone *and* the system audio (the other participants) — and writes a live, speaker-attributed transcript to a Markdown notes file.

## ✨ Features

- **Zero-Latency Dictation:** Powered by Groq's `whisper-large-v3` for near-instant speech-to-text.
- **Context-Aware Polishing:** Detects the app you're typing in (e.g. Slack, Mail, Xcode) and uses `llama-3.3-70b-versatile` to format dictation appropriately — casual for Slack, formal for Mail, code-friendly for IDEs.
- **Meeting Mode:** Captures system audio via CoreAudio **process taps** (no screen-recording permission required) alongside your microphone, producing a timestamped, speaker-labeled (**You** / _Them_) transcript.
- **Echo Suppression:** When you're on the built-in speaker instead of headphones, half-duplex gating stops the remote party's voice (picked up by your mic as echo) from being mislabeled as "You".
- **Global Shortcuts:** Push-to-talk dictation (hold Right Option), Esc to cancel a dictation, ⌃⌥M to toggle Meeting Mode, ⌃⌥P to pause/resume transcription, ⌃⌥N to open the notes — all system-wide, from any app.
- **Native macOS Integration:** Built entirely in Swift. CoreGraphics event taps for global hotkeys, Accessibility (`AXUIElement`) for text injection.
- **Settings Window:** A System Settings-style sidebar UI — configurable AI models, push-to-talk key, meeting overlay mode, speech-detection thresholds, notes folder, and speaker labels. Everything persists and applies live.
- **Guided Permissions:** A live permission-status panel and menu items to authorize Microphone, System Audio Recording, and Accessibility, plus a one-click **Reset All Permissions** that clears the TCC grants and relaunches for a clean re-prompt.
- **Secure Key Management:** Your API key is stored in the macOS Keychain.

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
1. **API Key:** GhostWriter prompts for a [Groq API Key](https://console.groq.com/keys) — enter your key starting with `gsk_`.
2. **Permissions:** macOS presents native prompts for **Microphone**, **System Audio Recording**, and **Accessibility**. Grant all three. (Accessibility must be toggled on in System Settings — that's a macOS requirement; the app detects the grant and starts the hotkey without needing a relaunch.)

### Dictation
1. Place your cursor in any text field, in any app.
2. Press and hold the push-to-talk key (**Right Option** by default, configurable in Settings) — a glowing indicator appears.
3. Speak naturally.
4. Release the key. GhostWriter transcribes, polishes, and types the result at your cursor.

### Meeting Mode
1. Open the menu-bar icon and choose **Meeting Mode**, or press **⌃⌥M** from anywhere.
2. GhostWriter listens to both your mic and the system audio and writes a live Markdown transcript, tagging each line as **You** or _Them_ (labels customizable).
3. A small pill overlay indicates recording is active — switch it to live captions or hide it entirely in Settings.
4. Choose **Meeting Mode** again to stop; the session is finalized to the notes file.

### Menu bar
- **Meeting Mode** (⌃⌥M) — start/stop meeting transcription.
- **Pause Transcription** (⌃⌥P) — mute note-taking mid-meeting without ending the session (writes *paused/resumed* markers to the notes).
- **Open Meeting Notes** (⌃⌥N) — the live notes file during a meeting, or the notes folder otherwise.
- **Settings…** — the settings window (see below).
- **Set API Key…**
- **Permissions ▸** — authorize Microphone / System Audio Recording / Accessibility, and **Reset All Permissions…** to revoke the TCC grants and relaunch for a fresh prompt.

### Global shortcuts
These work system-wide, from any app (they ride the same Accessibility event tap as the push-to-talk key):

| Shortcut | Action |
| --- | --- |
| Hold **Right Option** (configurable) | Push-to-talk dictation |
| **Esc** (while dictating) | Cancel the recording — nothing is typed |
| **⌃⌥M** | Start / stop Meeting Mode |
| **⌃⌥P** | Pause / resume meeting transcription |
| **⌃⌥N** | Open meeting notes |

### Settings
A sidebar-style settings window with five panes:

| Pane | Options (defaults in bold) |
| --- | --- |
| **General** | API key status; transcription model (**whisper-large-v3**); polishing model (**llama-3.3-70b-versatile**); reset all settings |
| **Dictation** | Push-to-talk key (**Right Option**, or Left Option / Right Command / Right Control / Fn) |
| **Meeting Mode** | Overlay mode (**minimal pill** / live captions / hidden); notes folder (**~/Documents/Notes**); speaker labels (**You** / **Them**); echo suppression (**on**, gate **0.4 s**); *Advanced (collapsed):* mic threshold (**−40 dBFS**), system-audio threshold (**−50 dBFS**), segment flush pause (**1.5 s**), max segment length (**25 s**) |
| **Shortcuts** | Reference card of all global shortcuts (push-to-talk, Esc, ⌃⌥M / ⌃⌥P / ⌃⌥N) |
| **Permissions** | Live status of Microphone, System Audio Recording, and Accessibility with shortcuts to the relevant Settings panes |

All values are stored in `UserDefaults` and take effect immediately — model and hotkey changes apply to the very next request/keypress, no restart needed. Every control has a per-item reset, plus a global "Reset All Settings".

## 🛠 Tech Stack & Architecture

- **Language:** Swift (macOS **14.2+** — required for CoreAudio process taps)
- **Dictation audio:** `AVFoundation` — 16 kHz PCM capture with RMS-based Voice Activity Detection.
- **System audio:** CoreAudio process taps — `CATapDescription` → `AudioHardwareCreateProcessTap` → aggregate device → direct `AudioDeviceIOProc` callback, converted to 16 kHz mono via `AVAudioConverter`. Uses only the **System Audio Recording** permission (`NSAudioCaptureUsageDescription`), not Screen Recording.
- **Input/Output:** `CoreGraphics` CGEvent taps for the global hotkey; `ApplicationServices` `AXUIElement` API for text injection.
- **UI:** SwiftUI for the API-key onboarding and the floating recording indicator.
- **AI backend:** REST calls to Groq's Whisper (`whisper-large-v3`) and Llama (`llama-3.3-70b-versatile`) models.

## 📁 Project Layout

| Path | Purpose |
| --- | --- |
| `Sources/HotkeyManager.swift` | Global hotkeys (push-to-talk, Esc, ⌃⌥ shortcuts) via CGEvent tap |
| `Sources/AudioCapture.swift` | Microphone capture + VAD |
| `Sources/SystemAudioCapture.swift` | System-audio capture via CoreAudio process taps |
| `Sources/GroqService.swift` | Groq transcription + polishing API client |
| `Sources/TextPolisher.swift` / `AppDetector.swift` | Context-aware formatting |
| `Sources/TextInjector.swift` | Accessibility-based text injection |
| `Sources/MeetingNotesWriter.swift` | Markdown transcript writer |
| `Sources/PermissionGuard.swift` | Mic / Accessibility / System-audio permission handling |
| `Sources/AppSettings.swift` | UserDefaults-backed settings store with defaults |
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

macOS keys each grant to the app's code signature, so re-signing with a different identity resets them. If a permission gets stuck, use **Reset All Permissions…** from the menu.

---
*Built natively for Apple Silicon and macOS.*
