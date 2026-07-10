import Foundation

// MARK: - Meeting Notes Writer
//
// Creates a timestamped markdown file in ~/Documents/Notes/ when a meeting starts
// and appends each transcribed segment as it arrives.

final class MeetingNotesWriter {

    private(set) var currentFilePath: URL?
    /// The most recently finished session's file (survives endSession).
    private(set) var lastCompletedFilePath: URL?

    // Rolling recent-transcript context used to self-prime the next segment's
    // transcription (Whisper attends to prior text, so names/jargon stay
    // consistent once they first appear). Best-effort and guarded, because
    // mic and system-audio segment tasks append concurrently.
    private let contextLock = NSLock()
    private var recentSegments: [String] = []

    /// The tail of the recent transcript, fed back as a transcription prompt
    /// hint for the next segment. Empty until the first segment lands.
    var promptContext: String {
        contextLock.lock(); defer { contextLock.unlock() }
        return recentSegments.joined(separator: " ")
    }

    private func rememberContext(_ text: String) {
        contextLock.lock(); defer { contextLock.unlock() }
        recentSegments.append(text)
        // Keep only the last couple of segments — Whisper's prompt window is
        // short and stale context adds no value.
        if recentSegments.count > 2 {
            recentSegments.removeFirst(recentSegments.count - 2)
        }
    }


    /// Read live from settings so a folder change applies to the next session.
    /// Includes the Year/Month subfolder when organization is enabled.
    private var notesDirectory: URL { AppSettings.shared.meetingDestinationFolder() }

    /// Every meeting notes file under the notes folder, searched recursively
    /// (files may live in Year/Month/Day subfolders), newest first — the
    /// filename encodes the full timestamp so name order is date order.
    ///
    /// The result is cached briefly: the menu, stats line, and Catalog
    /// all call this, and with years of notes a full tree walk + sort on every
    /// menu open would add up. A new meeting invalidates the cache.
    static func allMeetingFiles(under folder: URL) -> [URL] {
        cacheLock.lock()
        defer { cacheLock.unlock() }

        if let cached = fileCache,
           cached.folder == folder,
           Date().timeIntervalSince(cached.at) < 10 {
            return cached.files
        }

        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        let files = enumerator.compactMap { $0 as? URL }
            .filter { $0.lastPathComponent.hasPrefix("Meeting_") && $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        fileCache = (folder, files, Date())
        return files
    }

    /// Forget the cached file list (call when a notes file is created).
    static func invalidateFileCache() {
        cacheLock.lock()
        fileCache = nil
        cacheLock.unlock()
    }

    private static var fileCache: (folder: URL, files: [URL], at: Date)?
    private static let cacheLock = NSLock()

    // Formatters are expensive to create — build once. This class is only used
    // from the transcription Tasks one line at a time, so this is safe.
    // en_US_POSIX pins the Gregorian calendar and 0-23 hours regardless of the
    // user's locale — these strings are file/folder names and parsed back later.
    // Filename/day stamps use the shared POSIX formatters in DateDisplay.
    private static let fileNameFormatter = DateDisplay.posixTimestamp
    private static let dayFormatter = DateDisplay.posixDay
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return f
    }()
    private static let displayDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        return f
    }()

    // MARK: - Quick Notes

    /// Append a dictated quick note to today's QuickNotes file (created on
    /// first use) in the dedicated quick-notes folder — kept separate from
    /// meeting notes so history/search/assistant stay meetings-only.
    @discardableResult
    static func appendQuickNote(_ text: String) -> URL? {
        let folder = AppSettings.shared.quickNotesFolder
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            Log.meeting.error("❌ Could not create quick-notes folder: \(error.localizedDescription)")
            return nil
        }

        let fileURL = todaysQuickNotesURL()
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            let header = "# Quick Notes\n**\(displayDateFormatter.string(from: Date()))**\n\n---\n\n"
            try? header.write(to: fileURL, atomically: true, encoding: .utf8)
        }

        let time = timeFormatter.string(from: Date())
        guard let data = "**[\(time)]** \(text)\n\n".data(using: .utf8),
              let handle = try? FileHandle(forWritingTo: fileURL) else { return nil }
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
        Log.meeting.info("📝 Quick note saved")
        return fileURL
    }

    // MARK: - Dictation Archive

    /// Archive one dictation to its own Markdown file with metadata
    /// front-matter, in the dedicated dictations folder. Returns the URL, or
    /// nil on failure. The text is already polished and (if enabled) redacted.
    @discardableResult
    static func saveDictation(text: String, app: String, host: String?, style: String,
                              seconds: Int, words: Int) -> URL? {
        let now = Date()
        let folder = AppSettings.shared.dictationDestinationFolder(for: now)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            Log.dictation.error("❌ Could not create dictations folder: \(error.localizedDescription)")
            return nil
        }

        let stamp = fileNameFormatter.string(from: now)
        let fileURL = folder.appendingPathComponent("Dictation_\(stamp).md")

        // Quote free-text values — an app/host/style could contain a colon or
        // quote that would otherwise produce malformed YAML.
        func yaml(_ s: String) -> String {
            "\"\(s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
        }
        var lines = ["---",
                     "title: Dictation \(stamp)",
                     "date: \(ISO8601DateFormatter().string(from: now))",
                     "app: \(yaml(app))"]
        if let host, !host.isEmpty { lines.append("host: \(yaml(host))") }
        lines.append("style: \(yaml(style))")
        lines.append("duration: \(seconds)s")
        lines.append("words: \(words)")
        lines.append("tags: [dictation, ghostwriter]")
        lines.append("---")
        lines.append("")
        let content = lines.joined(separator: "\n") + "\n" + text + "\n"

        do {
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            Log.dictation.error("❌ Could not write dictation file: \(error.localizedDescription)")
            return nil
        }
        Log.dictation.info("📝 Dictation archived")
        return fileURL
    }

    /// Where today's quick notes live (whether or not the file exists yet).
    static func todaysQuickNotesURL() -> URL {
        AppSettings.shared.quickNotesFolder
            .appendingPathComponent("QuickNotes_\(dayFormatter.string(from: Date())).md")
    }

    /// Today's QuickNotes file if it exists, else the most recent one.
    static func latestQuickNotesFile() -> URL? {
        let today = todaysQuickNotesURL()
        if FileManager.default.fileExists(atPath: today.path) { return today }

        let folder = AppSettings.shared.quickNotesFolder
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix("QuickNotes_") && $0.pathExtension == "md" }
            .max { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: - Speaker Names

    /// Session-scoped display names: default label ("Them 2") → chosen name
    /// ("Alice"). Applied to every segment appended after the rename.
    private var nameOverrides: [String: String] = [:]

    /// Register a rename for the rest of the session. Renaming an
    /// already-renamed speaker re-targets the same underlying label.
    func setNameOverride(_ name: String, replacing oldLabel: String) {
        if let original = nameOverrides.first(where: { $0.value == oldLabel })?.key {
            nameOverrides[original] = name
        } else {
            nameOverrides[oldLabel] = name
        }
    }

    /// Rewrite every occurrence of a speaker label in a finished notes file.
    static func renameSpeaker(from old: String, to new: String, in file: URL) {
        guard old != new, !new.isEmpty,
              var content = try? String(contentsOf: file, encoding: .utf8) else { return }
        content = content
            .replacingOccurrences(of: "**\(old)**:", with: "**\(new)**:")
            .replacingOccurrences(of: "_\(old)_:", with: "_\(new)_:")
        try? content.write(to: file, atomically: true, encoding: .utf8)
    }

    /// Distinct speaker labels appearing in a notes file, in first-seen order.
    static func speakerLabels(in file: URL) -> [String] {
        guard let content = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        var labels: [String] = []
        let pattern = #/\*\*\[\d{2}:\d{2}:\d{2}\]\*\* (?:\*\*(.+?)\*\*|_(.+?)_):/#
        for line in content.split(whereSeparator: \.isNewline) {
            guard let match = line.firstMatch(of: pattern) else { continue }
            let label = String(match.1 ?? match.2 ?? "")
            if !label.isEmpty, !labels.contains(label) { labels.append(label) }
        }
        return labels
    }

    // MARK: - Session Lifecycle

    /// Call when meeting mode starts. Creates the notes file and writes the header.
    func beginSession() {
        nameOverrides.removeAll()
        contextLock.lock(); recentSegments.removeAll(); contextLock.unlock()
        do {
            try FileManager.default.createDirectory(at: notesDirectory, withIntermediateDirectories: true)

            let timestamp = Self.fileNameFormatter.string(from: Date())
            let fileName = "Meeting_\(timestamp).md"
            let fileURL = notesDirectory.appendingPathComponent(fileName)

            let displayFormatter = DateFormatter()
            displayFormatter.dateStyle = .long
            displayFormatter.timeStyle = .short
            let displayDate = displayFormatter.string(from: Date())

            var header = ""
            if AppSettings.shared.frontMatterEnabled {
                // Obsidian/Notion-friendly YAML front-matter
                let isoFormatter = ISO8601DateFormatter()
                header += """
                ---
                title: Meeting \(timestamp)
                date: \(isoFormatter.string(from: Date()))
                tags: [meeting, ghostwriter]
                ---

                """
            }
            header += "# Meeting Notes\n**\(displayDate)**\n\n---\n\n"
            try header.write(to: fileURL, atomically: true, encoding: .utf8)

            currentFilePath = fileURL
            Self.invalidateFileCache()
            Log.meeting.info("📝 Meeting notes → \(fileURL.path)")
        } catch {
            Log.meeting.error("❌ Could not create meeting notes file: \(error.localizedDescription)")
        }
    }

    /// Call when meeting mode stops. Writes a footer with duration.
    func endSession(startedAt: Date) {
        guard let fileURL = currentFilePath else { return }

        let elapsed = Int(Date().timeIntervalSince(startedAt))
        let duration = String(format: "%d:%02d", elapsed / 60, elapsed % 60)
        let footer = "\n---\n*Meeting duration: \(duration)*\n"

        append(footer, to: fileURL)
        lastCompletedFilePath = fileURL
        currentFilePath = nil
        Log.meeting.info("📝 Meeting notes saved")
    }

    /// Appends an AI-generated summary section to a finished notes file.
    func appendSummary(_ summary: String, to fileURL: URL) {
        append("\n# Summary\n\n\(summary)\n", to: fileURL)
        Log.meeting.info("📝 Summary appended")
    }

    /// Append an Agenda section as a Markdown checklist. `entries` are
    /// (text, covered, dynamic) — dynamic items are the topics the meeting
    /// itself raised, marked so they read apart from the planned agenda.
    func appendAgenda(_ entries: [(text: String, covered: Bool, dynamic: Bool)], to fileURL: URL) {
        guard !entries.isEmpty else { return }
        let lines = entries.map { e -> String in
            let box = e.covered ? "- [x]" : "- [ ]"
            let tag = e.dynamic ? " _(raised in meeting)_" : ""
            return "\(box) \(e.text)\(tag)"
        }
        append("\n# Agenda\n\n\(lines.joined(separator: "\n"))\n", to: fileURL)
        Log.meeting.info("🗒 Agenda appended")
    }

    /// Merge topic tags into the YAML front-matter `tags: [...]` line. No-op if
    /// the file has no front-matter (tags require it) or no new tags.
    static func addFrontMatterTags(_ tags: [String], to fileURL: URL) {
        let newTags = tags.filter { !$0.isEmpty }
        guard !newTags.isEmpty,
              var content = try? String(contentsOf: fileURL, encoding: .utf8),
              content.hasPrefix("---") else { return }

        var lines = content.components(separatedBy: "\n")
        guard let i = lines.firstIndex(where: { $0.hasPrefix("tags:") }) else { return }

        // Parse existing "tags: [a, b]" and append any that are new.
        let existing = lines[i]
            .drop(while: { $0 != "[" }).dropFirst().prefix(while: { $0 != "]" })
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var merged = existing
        for tag in newTags where !merged.contains(tag) { merged.append(tag) }
        lines[i] = "tags: [\(merged.joined(separator: ", "))]"
        content = lines.joined(separator: "\n")
        try? content.write(to: fileURL, atomically: true, encoding: .utf8)
        Log.meeting.info("🏷 Front-matter tags updated")
    }

    /// Slug a display name into a hyphenated tag token ("Acme Corp" → "acme-corp").
    private static func slug(_ s: String) -> String {
        let lowered = s.lowercased().unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) ? Character($0) : "-"
        }
        return String(lowered).split(separator: "-").joined(separator: "-")
    }

    /// Write structured entity fields (attendees / customer / project) into the
    /// front-matter and mirror them into `tags:` so tag search and the Obsidian
    /// graph pick them up. No-op without front-matter. Inserts each field once,
    /// after the `tags:` line; existing fields are left untouched.
    static func addMeetingMetadata(topics: [String], people: [String],
                                   customer: String?, project: String?,
                                   to fileURL: URL) {
        // Mirror entities into tags alongside the topic tags.
        var tagTokens = topics
        tagTokens += people.map(slug)
        if let c = customer { tagTokens.append(slug(c)) }
        if let p = project { tagTokens.append(slug(p)) }
        addFrontMatterTags(tagTokens.filter { !$0.isEmpty }, to: fileURL)

        // Structured fields for Dataview / Notion-style filtering.
        guard var content = try? String(contentsOf: fileURL, encoding: .utf8),
              content.hasPrefix("---") else { return }
        var lines = content.components(separatedBy: "\n")
        guard let tagsIdx = lines.firstIndex(where: { $0.hasPrefix("tags:") }) else { return }

        var inserts: [String] = []
        func addField(_ key: String, _ value: String) {
            guard !value.isEmpty, !lines.contains(where: { $0.hasPrefix("\(key):") }) else { return }
            inserts.append("\(key): \(value)")
        }
        if !people.isEmpty { addField("attendees", "[\(people.joined(separator: ", "))]") }
        if let c = customer { addField("customer", c) }
        if let p = project { addField("project", p) }
        guard !inserts.isEmpty else { return }

        lines.insert(contentsOf: inserts, at: tagsIdx + 1)
        content = lines.joined(separator: "\n")
        try? content.write(to: fileURL, atomically: true, encoding: .utf8)
        Log.meeting.info("🏷 Front-matter entities added")
    }

    /// Full text of a notes file (for summarization).
    func transcriptText(of fileURL: URL) -> String? {
        try? String(contentsOf: fileURL, encoding: .utf8)
    }

    // MARK: - Appending Transcripts

    /// Appends a transcribed segment with a timestamp and optional speaker label.
    /// `at` allows retried segments to carry their original capture time.
    func append(segment text: String, speaker: String = "Them", at date: Date = Date()) {
        guard let fileURL = currentFilePath else { return }

        let timestamp = Self.timeFormatter.string(from: date)

        // "You"/"Them" are role keys — map them to the user's custom labels
        // (falling back to defaults if a label was left empty in Settings).
        let settings = AppSettings.shared
        let you  = settings.speakerLabelYou.isEmpty  ? AppSettings.Default.speakerLabelYou  : settings.speakerLabelYou
        let them = settings.speakerLabelThem.isEmpty ? AppSettings.Default.speakerLabelThem : settings.speakerLabelThem
        // Diarization passes "Them 2", "Them 3", … — keep the numeric suffix
        // while still honoring the custom label.
        let isYou = speaker == "You"
        let plainLabel: String
        if isYou {
            plainLabel = you
        } else {
            let suffix = speaker.hasPrefix("Them ") ? " \(speaker.dropFirst(5))" : ""
            plainLabel = "\(them)\(suffix)"
        }
        // "Rename Speakers…" may have given this voice a real name.
        let display = nameOverrides[plainLabel] ?? plainLabel
        let speakerTag = isYou ? "**\(display)**" : "_\(display)_"
        let line = "**[\(timestamp)]** \(speakerTag): \(text)\n\n"
        append(line, to: fileURL)
        rememberContext(text)
    }

    /// Appends an italic event marker (e.g. "Transcription paused") with a timestamp.
    func appendMarker(_ text: String) {
        guard let fileURL = currentFilePath else { return }
        let timestamp = Self.timeFormatter.string(from: Date())
        append("*[\(timestamp)] — \(text)*\n\n", to: fileURL)
    }

    // MARK: - Private

    private func append(_ text: String, to url: URL) {
        guard let data = text.data(using: .utf8),
              let handle = try? FileHandle(forWritingTo: url) else { return }
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    }
}
