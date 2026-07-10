import Foundation
import os

// MARK: - Logging
//
// Unified os.Logger categories. Unlike print(), these are visible in
// Console.app with proper subsystem filtering, carry log levels, and are
// near-free when no one is streaming them.

enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.ghostwriter.app"

    /// App lifecycle, menu, windows.
    static let app = Logger(subsystem: subsystem, category: "app")
    /// Push-to-talk dictation flow.
    static let dictation = Logger(subsystem: subsystem, category: "dictation")
    /// Meeting mode: capture, segmenting, notes.
    static let meeting = Logger(subsystem: subsystem, category: "meeting")
    /// CoreAudio system-audio tap.
    static let audio = Logger(subsystem: subsystem, category: "audio")
    /// TCC permissions.
    static let permissions = Logger(subsystem: subsystem, category: "permissions")
    /// Groq API calls.
    static let api = Logger(subsystem: subsystem, category: "api")
    /// Global hotkeys.
    static let hotkey = Logger(subsystem: subsystem, category: "hotkey")
}
