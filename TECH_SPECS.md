# Voiceeee — Technical Specifications
> *Privacy-First, Zero-Latency Voice Intelligence for macOS*

**Version**: 0.1.0 (Sprint 1)  
**Last Updated**: 2026-04-21  
**Status**: 🚧 Active Development

---

## 1. Product Philosophy

### 1.1 Zero-Latency Expectation
Transcription must feel **instantaneous**. The pipeline is designed for sub-200ms perceived latency by streaming audio to Groq's Whisper-v3 endpoint immediately after the user stops speaking. No local model warmup. No batch processing. The moment you release the Right Option key, text appears.

### 1.2 Contextual Intelligence
Voiceeee isn't just a mic — it's a **secretary that knows where you are**. When you dictate in Slack, it outputs casual, emoji-friendly text. In Apple Mail, it produces formal prose. In Cursor/VS Code, it formats as code comments or documentation. The app detects the active application via `NSWorkspace` and passes context to the Llama-3.3-70b polishing layer.

### 1.3 Privacy First
- **Local VAD**: Voice Activity Detection runs entirely on-device using RMS energy thresholds
- **Memory-only buffers**: Audio lives in RAM circular buffers. **Zero disk writes of audio data.**
- **No telemetry**: No analytics, no crash reporting that includes audio data
- **Explicit transmission**: Audio only leaves the device when the user holds the hotkey AND speaks above the noise threshold

### 1.4 Invisible UI
The app has no Dock icon (`LSUIElement = true`). No menu bar clutter by default. The only visible element is a small floating glow indicator that appears when the user holds the hotkey. It pulses with audio levels and shows processing state. When idle, the app is completely invisible.

---

## 2. System Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    VoiceeeeApp (SwiftUI)                     │
│                    LSUIElement = true                         │
│                    No Dock Icon                              │
├──────────────────┬───────────────────────────────────────────┤
│                  │                                           │
│   Sentinel       │   Core Pipeline                          │
│   ┌────────────┐ │   ┌────────────┐   ┌──────────────────┐ │
│   │HotkeyMgr   │─┼──▶│AudioCapture│──▶│GroqTranscriber   │ │
│   │CGEventTap  │ │   │AVAudioEng  │   │Whisper-v3        │ │
│   │Right ⌥ key │ │   │16kHz PCM   │   └────────┬─────────┘ │
│   └────────────┘ │   └────────────┘            │           │
│                  │        │                     ▼           │
│   Permission     │   ┌────────────┐   ┌──────────────────┐ │
│   ┌────────────┐ │   │    VAD     │   │TextPolisher      │ │
│   │PermGuard   │ │   │RMS Noise   │   │Llama-3.3-70b    │ │
│   │Mic + A11y  │ │   │Gate        │   │App-Aware         │ │
│   └────────────┘ │   └────────────┘   └────────┬─────────┘ │
│                  │                              │           │
│   App Context    │                              ▼           │
│   ┌────────────┐ │                    ┌──────────────────┐ │
│   │AppDetector │─┼───────────────────▶│TextInjector      │ │
│   │NSWorkspace │ │                    │AXUIElement       │ │
│   └────────────┘ │                    │Direct @ Cursor   │ │
│                  │                    └──────────────────┘ │
├──────────────────┴───────────────────────────────────────────┤
│                    GlowOverlay (SwiftUI)                      │
│              NSPanel • Floating • Always On Top              │
│         Audio Level Pulsing • Processing States              │
└─────────────────────────────────────────────────────────────┘
```

---

## 3. Feature Specifications

### 3.1 Input — The Sentinel (Hotkey Manager)

| Property | Value |
|---|---|
| **Trigger** | Right Option key (key code 61) |
| **Mode** | Press-and-hold (key-down starts, key-up stops) |
| **Implementation** | `CGEventTap` at `kCGHIDEventTap` |
| **Scope** | Global — works in ALL applications |
| **Permissions** | Requires Accessibility permission |

**Behavior:**
- `keyDown` (Right ⌥): Start audio capture → show Glow overlay
- `keyUp` (Right ⌥): Stop capture → send to Groq → inject text → hide Glow
- Double-tap Right ⌥: Toggle always-listening mode (future)

### 3.2 Audio — Capture Pipeline

| Property | Value |
|---|---|
| **Engine** | `AVAudioEngine` |
| **Sample Rate** | 16,000 Hz (16kHz) |
| **Format** | Linear PCM, 16-bit signed integer, mono |
| **Buffer** | In-memory circular buffer (max 60 seconds) |
| **Disk Writes** | **NONE** — privacy guarantee |

**Implementation:**
```swift
let format = AVAudioFormat(
    commonFormat: .pcmFormatInt16,
    sampleRate: 16000,
    channels: 1,
    interleaved: false
)!
```

### 3.3 VAD — Voice Activity Detection

| Property | Value |
|---|---|
| **Method** | RMS Energy Threshold |
| **Threshold** | -40 dBFS (configurable) |
| **Debounce** | 300ms trailing silence before stop |
| **Purpose** | Prevent sending dead air to Groq API |

**Algorithm:**
1. Calculate RMS of each audio buffer frame
2. Convert to dBFS: `20 * log10(rms)`
3. If above threshold → voice active → accumulate buffer
4. If below threshold for > 300ms → voice inactive → stop accumulation

### 3.4 Brain — Groq AI Pipeline

**Stage 1: Transcription**
| Property | Value |
|---|---|
| **Model** | `whisper-large-v3` |
| **Endpoint** | `POST https://api.groq.com/openai/v1/audio/transcriptions` |
| **Input** | WAV file from memory buffer |
| **Output** | Raw transcribed text |
| **Latency Target** | < 500ms for 10s of audio |

**Stage 2: App-Aware Polishing**
| Property | Value |
|---|---|
| **Model** | `llama-3.3-70b-versatile` |
| **Endpoint** | `POST https://api.groq.com/openai/v1/chat/completions` |
| **Input** | Raw text + active app context |
| **Output** | Polished, context-appropriate text |

**Context Rules:**
| Active App | Polishing Style |
|---|---|
| Slack / Discord | Casual, concise, emoji-allowed |
| Apple Mail / Outlook | Professional, properly punctuated |
| Cursor / VS Code | Code comments or documentation format |
| Safari / Chrome | Natural prose, web-form friendly |
| Notes / Pages | Clean paragraphs, proper formatting |
| Default | Standard professional English |

### 3.5 Output — Text Injection

| Property | Value |
|---|---|
| **Method** | `AXUIElement` Accessibility API |
| **Mechanism** | Set `kAXValueAttribute` on focused element |
| **Fallback** | Clipboard paste (`⌘V`) if AX injection fails |
| **Permissions** | Requires Accessibility permission |

**Advantages over clipboard:**
- No clipboard pollution (user's clipboard preserved)
- Works at exact cursor position
- Supports undo in target app

### 3.6 The Glow — Visual Overlay

| Property | Value |
|---|---|
| **Framework** | SwiftUI hosted in `NSPanel` |
| **Window Level** | `.floating` (above all apps) |
| **Position** | Near cursor or bottom-center of active screen |
| **Interaction** | Non-interactive (click-through) |
| **Dock Icon** | Hidden (`LSUIElement = true`) |

**States:**
| State | Visual |
|---|---|
| Idle | Invisible |
| Listening | Pulsing blue/cyan glow, scales with audio RMS |
| Processing | Spinning/morphing animation, "Processing..." |
| Done | Brief green flash, auto-dismiss after 500ms |
| Error | Red flash with brief error message |

---

## 4. Permissions Required

| Permission | Why | When Requested |
|---|---|---|
| **Microphone** | Audio capture via AVAudioEngine | First launch |
| **Accessibility** | CGEventTap + AXUIElement text injection | First launch |

---

## 5. Dependencies

| Dependency | Purpose | Type |
|---|---|---|
| `AVFoundation` | Audio capture | System Framework |
| `CoreGraphics` | CGEventTap hotkeys | System Framework |
| `ApplicationServices` | AXUIElement text injection | System Framework |
| `SwiftUI` | Glow overlay UI | System Framework |
| `AppKit` | NSPanel, NSWorkspace | System Framework |

**External:**
| Dependency | Purpose |
|---|---|
| Groq API | Whisper-v3 transcription + Llama-3.3-70b polishing |

---

## 6. Privacy & Security

- ❌ No audio written to disk — ever
- ❌ No analytics or telemetry
- ❌ No background recording — only when hotkey is held
- ✅ API key stored in macOS Keychain
- ✅ Audio transmitted only over HTTPS to Groq
- ✅ Memory buffers zeroed after processing
- ✅ Open source — audit the code yourself
