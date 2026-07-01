# 👻 GhostWriter

> A zero-latency, context-aware macOS dictation agent that magically types polished text into any active window — and now transcribes your meetings.

GhostWriter is a lightweight native macOS utility that lives in your menu bar. Hold down the **Right Option** key to speak, and GhostWriter instantly transcribes and polishes your speech using Groq's ultra-fast Whisper and Llama models, injecting the perfect text directly into whatever app you're currently using.

It also has a **Meeting Mode** that captures both sides of a conversation — your microphone *and* the system audio (the other participants) — and writes a live, speaker-attributed transcript to a Markdown notes file.

## ✨ Features

- **Zero-Latency Dictation:** Powered by Groq's `whisper-large-v3` for near-instant speech-to-text.
- **Context-Aware Polishing:** Detects the app you're typing in (e.g. Slack, Mail, Xcode) and uses `llama-3.3-70b-versatile` to format dictation appropriately — casual for Slack, formal for Mail, code-friendly for IDEs.
- **Meeting Mode:** Captures system audio via CoreAudio **process taps** (no screen-recording permission required) alongside your microphone, producing a timestamped, speaker-labeled (**You** / _Them_) transcript.
- **Echo Suppression:** When you're on the built-in speaker instead of headphones, half-duplex gating stops the remote party's voice (picked up by your mic as echo) from being mislabeled as "You".
- **Native macOS Integration:** Built entirely in Swift. CoreGraphics event taps for global hotkeys, Accessibility (`AXUIElement`) for text injection.
- **Guided Permissions:** In-app menu items to authorize Microphone, System Audio Recording, and Accessibility, plus a one-click **Reset All Permissions** that clears the TCC grants and relaunches for a clean re-prompt.
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
2. Press and hold the **Right Option** key — a glowing indicator appears.
3. Speak naturally.
4. Release the key. GhostWriter transcribes, polishes, and types the result at your cursor.

### Meeting Mode
1. Open the menu-bar icon and choose **Meeting Mode** (⌘M).
2. GhostWriter listens to both your mic and the system audio and writes a live Markdown transcript, tagging each line as **You** or _Them_.
3. Choose **Meeting Mode** again to stop; the session is finalized to the notes file.

### Menu-bar actions
- **Set API Key…**
- **Authorize Microphone… / System Audio Recording… / Accessibility…** — trigger the native prompt or open the relevant Settings pane.
- **Reset All Permissions…** — revoke GhostWriter's TCC grants and relaunch for a fresh prompt.

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
| `Sources/HotkeyManager.swift` | Global Right-Option hotkey via CGEvent tap |
| `Sources/AudioCapture.swift` | Microphone capture + VAD |
| `Sources/SystemAudioCapture.swift` | System-audio capture via CoreAudio process taps |
| `Sources/GroqService.swift` | Groq transcription + polishing API client |
| `Sources/TextPolisher.swift` / `AppDetector.swift` | Context-aware formatting |
| `Sources/TextInjector.swift` | Accessibility-based text injection |
| `Sources/MeetingNotesWriter.swift` | Markdown transcript writer |
| `Sources/PermissionGuard.swift` | Mic / Accessibility / System-audio permission handling |
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
