# Voiceeee — Project Log

## Session 1: Foundation Build
**Date**: 2026-04-21  
**Duration**: 2 hours (90 minutes remaining at start)  
**Objective**: Ship Sprint 1 — Foundation + Permissions + Hotkey Manager

---

### Timeline

| Time | Status | Task |
|------|--------|------|
| 10:51 | ✅ | Skills reviewed (SwiftUI Expert, Liquid Glass, UI Patterns) |
| 10:55 | ✅ | TECH_SPECS.md created |
| 10:55 | ✅ | PROJECT_LOG.md created |
| 10:56 | ✅ | Package.swift — SPM project initialized |
| 11:00 | ✅ | VoiceeeeApp.swift — App lifecycle + AppDelegate |
| 11:00 | ✅ | PermissionGuard.swift — Mic + Accessibility |
| 11:00 | ✅ | HotkeyManager.swift — CGEventTap (Right ⌥) |
| 11:00 | ✅ | AudioCapture.swift — AVAudioEngine 16kHz PCM |
| 11:00 | ✅ | VoiceActivityDetector.swift — RMS noise-gate VAD |
| 11:00 | ✅ | GroqService.swift — Whisper-v3 transcription |
| 11:00 | ✅ | TextPolisher.swift — Llama-3.3-70b polishing |
| 11:00 | ✅ | AppDetector.swift — Active app categorization |
| 11:00 | ✅ | GlowOverlayView.swift — Floating SwiftUI panel |
| 11:00 | ✅ | TextInjector.swift — AXUIElement + clipboard fallback |
| 11:03 | ✅ | **`swift build` PASSED — Build complete (2.74s)** |
| 11:08 | ✅ | KeychainService.swift — Groq key stored in Keychain (never in source) |
| 11:08 | ✅ | GroqService + TextPolisher wired to KeychainService |
| 11:09 | ✅ | **Groq Llama-3.3-70b: HTTP 200** |
| 11:09 | ✅ | **Groq Whisper-v3: HTTP 200** — full API pipeline validated |

---

### Decision Log

| # | Decision | Alternatives | Rationale |
|---|----------|-------------|-----------|
| 1 | Swift Package Manager (no Xcode project file) | Xcode project, Tuist | SPM is lightweight, reproducible, no `.xcodeproj` bloat |
| 2 | CGEventTap for hotkeys | NSEvent.addGlobalMonitor, HotKey library | CGEventTap is the most reliable for modifier-only keys |
| 3 | Right Option key as trigger | Left Option, Function key, custom shortcut | Right Option is rarely used, won't conflict with system shortcuts |
| 4 | AXUIElement for text injection | Clipboard paste, CGEventPost | AX preserves clipboard, works at cursor, supports undo |
| 5 | NSPanel for floating overlay | NSWindow, SwiftUI WindowGroup | NSPanel stays above all windows, click-through, no activation |
| 6 | In-memory only audio | Temp file on disk | Privacy guarantee — no audio ever touches the filesystem |

---

### Assumptions

- User has macOS 14+ (Sonoma or later)
- User has a Groq API key
- User will grant Mic + Accessibility permissions
- Internet connection available for Groq API calls
- Right Option key is not remapped by the user

---

### Risks

| Risk | Severity | Mitigation |
|------|----------|------------|
| Accessibility permission denied | High | Clear onboarding flow with System Preferences deep link |
| Groq API latency spike | Medium | Show "Processing..." state, timeout after 10s |
| CGEventTap invalidated by macOS | Medium | Re-create tap on invalidation callback |
| AXUIElement injection fails in some apps | Medium | Fallback to clipboard paste |
