# 👻 GhostWriter

> A zero-latency, context-aware macOS dictation agent that magically types polished text into any active window.

GhostWriter is a lightweight native macOS utility that sits in your menu bar. Hold down the **Right Option** key to speak, and GhostWriter instantly transcribes and polishes your speech using Groq's ultra-fast Whisper and Llama 3 models, injecting the perfect text directly into whatever app you're currently using.

## ✨ Features

- **Zero-Latency Transcription:** Powered by Groq's `whisper-large-v3` for near-instant speech-to-text.
- **Context-Aware Polishing:** Automatically detects the app you are typing in (e.g., Slack, Mail, Xcode) and uses `llama-3.3-70b-versatile` to format your dictation appropriately (casual for Slack, formal for Mail, code-friendly for IDEs).
- **Native macOS Integration:** Built completely in Swift. Uses CoreGraphics event tapping for global hotkeys and Accessibility APIs (`AXUIElement`) to inject text seamlessly into your cursor's current position.
- **Secure Key Management:** Safely stores your API key in the macOS Keychain.

## 🚀 Installation

Because GhostWriter relies on global system hotkeys and accessibility features, it needs to be packaged cleanly to bypass macOS Gatekeeper quarantines. 

We've provided a simple build and deployment script:

1. Clone this repository to your Mac.
2. Open your terminal and run the ship script:
   ```bash
   ./ship.sh
   ```
3. The script will compile the Swift binary and create a `.release/GhostWriter.zip` file.
4. Unzip the file and double-click `install.command`. This will securely move the app to your `/Applications` folder, strip quarantine flags, and launch the app.

## ⚙️ Setup & Usage

1. **API Key:** On first launch, GhostWriter will prompt you for a [Groq API Key](https://console.groq.com/keys). Enter your key starting with `gsk_`.
2. **Permissions:** macOS will prompt you to grant **Microphone** and **Accessibility** permissions. Follow the prompts to enable them in System Settings.
3. **Dictate:** Place your cursor in any text field, in any app.
4. **Hold:** Press and hold the **Right Option** key. A glowing indicator will appear on your screen.
5. **Speak:** Talk naturally.
6. **Release:** Let go of the key. GhostWriter will process your speech and instantly type out the polished text!

## 🛠 Tech Stack & Architecture

- **Language:** Swift 5.9 (macOS 14.0+)
- **Audio:** `AVFoundation` (16kHz PCM audio capture & RMS-based Voice Activity Detection)
- **Input/Output:** `CoreGraphics` (CGEvent taps for hotkeys) & `ApplicationServices` (AXUIElement API for text injection)
- **UI:** SwiftUI (for the API key onboarding and the floating recording indicator)
- **AI Backend:** REST API calls to Groq's Whisper and Llama models.

---
*Built natively for Apple Silicon and macOS.*
