import Foundation

// MARK: - File Log
//
// A persistent, size-rotated plain-text diagnostic log at
// `~/Library/Logs/GhostWriter/ghostwriter.log`. Every `Log.<category>` call is
// mirrored here (see `AppLogger`), so "what just happened?" survives a relaunch
// and can be read, filtered, copied, or exported from Settings → Diagnostics —
// no Console.app or terminal needed.
//
// One line per entry:
//     2026-10-06 10:12:03.123 [ERROR] [api] ✖ chat "Meeting summary" …
//
// Privacy: the log is metadata-only by convention. Callers record sizes, counts,
// durations, status codes, and ids — never transcript text, prompts, or keys.
//
// Rotation: when the active file passes `maxBytes` it becomes `ghostwriter.1.log`
// (older ones shift up; the oldest of `rotatedCopies` is dropped), capping disk
// use at roughly `maxBytes * (rotatedCopies + 1)`.
//
// Thread-safe: writes are serialised onto a private utility queue, so logging
// from audio or network threads never blocks them.

final class FileLog: @unchecked Sendable {

    static let shared = FileLog()

    enum Level: Int, CaseIterable, Comparable {
        case debug, info, warning, error

        /// Fixed-width tag as written to the file (also what the viewer filters on).
        var tag: String {
            switch self {
            case .debug:   return "DEBUG"
            case .info:    return "INFO "
            case .warning: return "WARN "
            case .error:   return "ERROR"
            }
        }

        var title: String {
            switch self {
            case .debug:   return "Debug"
            case .info:    return "Info"
            case .warning: return "Warnings"
            case .error:   return "Errors"
            }
        }

        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    /// Debug-level lines are only written when Verbose logging is on. Read from
    /// UserDefaults (where `AppSettings` persists it) so any thread can check it
    /// cheaply without touching the main-actor settings object.
    static var verbose: Bool {
        UserDefaults.standard.bool(forKey: AppSettings.Key.verboseLogging)
    }

    private let queue = DispatchQueue(label: "com.ghostwriter.filelog", qos: .utility)
    private let directory: URL
    private let maxBytes: UInt64 = 2_000_000
    private let rotatedCopies = 4

    // All mutable state below is confined to `queue`.
    private var handle: FileHandle?
    private var size: UInt64 = 0
    private var wroteSessionHeader = false
    private let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private init() {
        directory = AppPaths.logs()
    }

    /// The active log file.
    var currentURL: URL { directory.appendingPathComponent("ghostwriter.log") }

    /// The folder holding the active and rotated logs (for "Reveal in Finder").
    var folderURL: URL { directory }

    // MARK: Write

    /// Append one entry. Debug entries are dropped unless verbose logging is on.
    func write(_ level: Level, category: String, _ message: String) {
        if level == .debug && !Self.verbose { return }
        let now = Date()
        queue.async { [self] in
            // One entry per line, so the file stays grep- and filter-friendly.
            let flat = message.replacingOccurrences(of: "\n", with: " ⏎ ")
            append("\(stamp.string(from: now)) [\(level.tag)] [\(category)] \(flat)\n")
        }
    }

    private func append(_ line: String) {
        if !wroteSessionHeader {
            wroteSessionHeader = true
            append(sessionHeader())
        }
        let bytes = Data(line.utf8)
        if handle == nil { open() }
        if size + UInt64(bytes.count) > maxBytes { rotate() }
        guard let handle else { return }
        do {
            try handle.write(contentsOf: bytes)
            size += UInt64(bytes.count)
        } catch {
            // Never recurse into logging from the logger.
            self.handle = nil
        }
    }

    private func sessionHeader() -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        return "\(stamp.string(from: Date())) [INFO ] [app] ── GhostWriter \(version) (\(build)) · macOS \(os) · verbose=\(Self.verbose) ──\n"
    }

    private func open() {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: currentURL.path) {
            fm.createFile(atPath: currentURL.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: currentURL)
        size = (try? handle?.seekToEnd()) ?? 0
    }

    /// Shift `ghostwriter.N.log` up by one (dropping the oldest) and start fresh.
    private func rotate() {
        try? handle?.close()
        handle = nil
        let fm = FileManager.default
        try? fm.removeItem(at: rotatedURL(rotatedCopies))
        for n in stride(from: rotatedCopies - 1, through: 1, by: -1) {
            try? fm.moveItem(at: rotatedURL(n), to: rotatedURL(n + 1))
        }
        try? fm.moveItem(at: currentURL, to: rotatedURL(1))
        open()
    }

    private func rotatedURL(_ n: Int) -> URL {
        directory.appendingPathComponent("ghostwriter.\(n).log")
    }

    // MARK: Read

    /// Every log file that exists, oldest first (rotated copies, then current).
    private func existingFiles() -> [URL] {
        let fm = FileManager.default
        let rotated = (1...rotatedCopies).reversed().map(rotatedURL)
        return (rotated + [currentURL]).filter { fm.fileExists(atPath: $0.path) }
    }

    /// The full log text, oldest → newest (for Export / Copy all).
    func fullText() -> String {
        queue.sync {
            return existingFiles()
                .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
                .joined()
        }
    }

    /// The most recent `limit` entries (oldest first), optionally limited to a
    /// minimum level and/or one category. Lines are returned verbatim. Reads the
    /// newest file first and stops as soon as `limit` lines match, so a tail view
    /// stays cheap even with five rotated files on disk.
    func recentLines(limit: Int = 400, minLevel: Level = .debug, category: String? = nil) -> [String] {
        let wanted = Level.allCases.filter { $0 >= minLevel }.map { "[\($0.tag)]" }
        let categoryTag = category.map { "[\($0)]" }
        return queue.sync {
            var picked: [String] = []
            for url in existingFiles().reversed() {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
                    guard wanted.contains(where: { line.contains($0) }) else { continue }
                    if let categoryTag, !line.contains(categoryTag) { continue }
                    picked.append(String(line))
                    if picked.count >= limit { return picked.reversed() }
                }
            }
            return picked.reversed()
        }
    }

    /// The logger categories (for the viewer's filter menu) — mirrors `Log`.
    static let categories = ["app", "dictation", "meeting", "audio", "permissions", "api", "hotkey"]

    // MARK: Maintenance

    /// Delete every log file (the active one restarts empty with a fresh header).
    func clear() {
        queue.sync {
            try? handle?.close()
            handle = nil
            size = 0
            wroteSessionHeader = false
            for url in existingFiles() { try? FileManager.default.removeItem(at: url) }
        }
    }

    /// Total bytes on disk across all log files.
    func diskUsage() -> Int {
        queue.sync {
            existingFiles().reduce(0) { sum, url in
                sum + ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0)
            }
        }
    }
}
