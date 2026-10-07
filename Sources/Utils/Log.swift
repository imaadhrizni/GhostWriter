import Foundation
import os

// MARK: - Logging
//
// One logging surface with two sinks:
//   • os.Logger — live in Console.app (filter by the app's subsystem), and
//   • FileLog   — a persistent, rotated file shown in Settings → Diagnostics.
//
// Call sites are unchanged (`Log.meeting.info("…")`); each call fans out to both.
// Messages are plain Strings and are logged *public* in both sinks — so, by
// convention, never put transcript text, prompts, or secrets in a message: log
// sizes, counts, durations, status codes, and ids instead. (The old
// `OSLogMessage` default silently redacted interpolated values to `<private>`,
// which made persisted logs useless for diagnosis.)

/// A category-scoped logger that writes to os.Logger and the persistent `FileLog`.
struct AppLogger: Sendable {
    private let logger: Logger
    private let category: String

    init(subsystem: String, category: String) {
        self.logger = Logger(subsystem: subsystem, category: category)
        self.category = category
    }

    /// Verbose detail — written to the file only when Verbose logging is on.
    func debug(_ message: @autoclosure () -> String) {
        let text = message()
        logger.debug("\(text, privacy: .public)")
        FileLog.shared.write(.debug, category: category, text)
    }

    func info(_ message: @autoclosure () -> String) {
        let text = message()
        logger.info("\(text, privacy: .public)")
        FileLog.shared.write(.info, category: category, text)
    }

    func warning(_ message: @autoclosure () -> String) {
        let text = message()
        logger.warning("\(text, privacy: .public)")
        FileLog.shared.write(.warning, category: category, text)
    }

    func error(_ message: @autoclosure () -> String) {
        let text = message()
        logger.error("\(text, privacy: .public)")
        FileLog.shared.write(.error, category: category, text)
    }
}

enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.ghostwriter.app"

    /// App lifecycle, menu, windows.
    static let app = AppLogger(subsystem: subsystem, category: "app")
    /// Push-to-talk dictation flow.
    static let dictation = AppLogger(subsystem: subsystem, category: "dictation")
    /// Meeting mode: capture, segmenting, notes.
    static let meeting = AppLogger(subsystem: subsystem, category: "meeting")
    /// CoreAudio system-audio tap.
    static let audio = AppLogger(subsystem: subsystem, category: "audio")
    /// TCC permissions.
    static let permissions = AppLogger(subsystem: subsystem, category: "permissions")
    /// Groq API calls.
    static let api = AppLogger(subsystem: subsystem, category: "api")
    /// Global hotkeys.
    static let hotkey = AppLogger(subsystem: subsystem, category: "hotkey")
}
