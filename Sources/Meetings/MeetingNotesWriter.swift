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

    /// Timestamped bookmarks (seconds since start) dropped via the hotkey during
    /// the meeting; written out as a jump-list at finalize. Reset each session.
    private var bookmarks: [(elapsed: Int, note: String)] = []

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
    /// Long date + short time (e.g. "3 July 2026 at 2:30 PM"), localized — the
    /// human-readable stamp written into note bodies.
    private static let displayDateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .short
        return f
    }()

    /// Quote a free-text value as a safe double-quoted YAML scalar — an app,
    /// title, or filename could contain a colon or quote that would otherwise
    /// produce malformed front-matter. Single source of truth for YAML escaping.
    static func yamlScalar(_ s: String) -> String {
        "\"\(s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }

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

        let yaml = Self.yamlScalar
        var lines = ["---",
                     "title: Dictation \(stamp)",
                     "date: \(DateDisplay.iso8601.string(from: now))",
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
              var content = file.readText() else { return }
        content = content
            .replacingOccurrences(of: "**\(old)**:", with: "**\(new)**:")
            .replacingOccurrences(of: "_\(old)_:", with: "_\(new)_:")
        try? content.write(to: file, atomically: true, encoding: .utf8)
    }

    /// Distinct speaker labels appearing in a notes file, in first-seen order.
    static func speakerLabels(in file: URL) -> [String] {
        guard let content = file.readText() else { return [] }
        var labels: [String] = []
        let pattern = #/\*\*\[\d{2}:\d{2}:\d{2}\]\*\* (?:\*\*(.+?)\*\*|_(.+?)_):/#
        for line in content.split(whereSeparator: \.isNewline) {
            guard let match = line.firstMatch(of: pattern) else { continue }
            let label = String(match.1 ?? match.2 ?? "")
            if !label.isEmpty, !labels.contains(label) { labels.append(label) }
        }
        return labels
    }

    /// Write a completed meeting note from an imported audio file's transcript.
    /// Dates and duration come from the source file's own metadata so the note
    /// is filed under when it was *recorded*, not when it was imported. Returns
    /// the file URL (nil on write failure). The caller links it into the Catalog.
    static func importAudioNote(transcript: String, recordedAt: Date,
                                sourceFilename: String, duration: TimeInterval?,
                                title: String? = nil) -> URL? {
        let noteTitle = (title?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? sourceFilename
        let folder = AppSettings.shared.meetingDestinationFolder(for: recordedAt)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            Log.meeting.error("❌ Could not create notes folder for import: \(error.localizedDescription)")
            return nil
        }

        let stamp = fileNameFormatter.string(from: recordedAt)
        let fileURL = folder.appendingPathComponent("Meeting_\(stamp).md")

        let displayDate = Self.displayDateTimeFormatter.string(from: recordedAt)

        let secs = duration.map { Int($0.rounded()) }
        let durationText = secs.map { String(format: "%d:%02d", $0 / 60, $0 % 60) }

        let yaml = Self.yamlScalar

        var content = ""
        if AppSettings.shared.frontMatterEnabled {
            let iso = DateDisplay.iso8601.string(from: recordedAt)
            var fm = ["---",
                      "title: \(yaml(noteTitle))",
                      "date: \(iso)",
                      "gw_meeting_type: general",
                      "gw_source: import",
                      "gw_source_file: \(yaml(sourceFilename))"]
            if let secs { fm.append("gw_duration: \(secs)") }
            fm.append("tags: [meeting, ghostwriter, imported]")
            fm.append("---")
            fm.append("")
            content += fm.joined(separator: "\n") + "\n"
        }
        content += "# Meeting Notes\n**\(displayDate)**\n\n"
        let sourceLine = durationText.map { "*Imported from `\(sourceFilename)` · \($0)*" }
            ?? "*Imported from `\(sourceFilename)`*"
        content += "\(sourceLine)\n\n---\n\n"
        content += transcript.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"

        do {
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            Log.meeting.error("❌ Could not write imported note: \(error.localizedDescription)")
            return nil
        }
        Self.invalidateFileCache()
        Log.meeting.info("📝 Imported audio note → \(fileURL.path)")
        return fileURL
    }

    // MARK: - Session Lifecycle

    /// Call when meeting mode starts. Creates the notes file and writes the header.
    func beginSession() {
        nameOverrides.removeAll()
        bookmarks.removeAll()
        contextLock.lock(); recentSegments.removeAll(); contextLock.unlock()
        do {
            try FileManager.default.createDirectory(at: notesDirectory, withIntermediateDirectories: true)

            let timestamp = Self.fileNameFormatter.string(from: Date())
            let fileName = "Meeting_\(timestamp).md"
            let fileURL = notesDirectory.appendingPathComponent(fileName)

            let displayDate = Self.displayDateTimeFormatter.string(from: Date())

            var header = ""
            if AppSettings.shared.frontMatterEnabled {
                // Obsidian/Notion-friendly YAML front-matter.
                // Record the meeting type so the note viewer can suggest the
                // right draft documents without guessing from headings.
                let meetingType = AppSettings.shared.selectedTemplateID
                header += """
                ---
                title: Meeting \(timestamp)
                date: \(DateDisplay.iso8601.string(from: Date()))
                gw_meeting_type: \(meetingType)
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

    /// Drop a timestamped bookmark at the current point in the meeting: writes
    /// an inline marker into the transcript (so you can find the moment in
    /// context) and remembers it for the end-of-meeting jump-list. `elapsed` is
    /// seconds since the meeting began. No-op if no file is open.
    func addBookmark(elapsed: Int, note: String = "") {
        guard let fileURL = currentFilePath else { return }
        bookmarks.append((elapsed, note))
        let suffix = note.isEmpty ? "" : " — \(note)"
        append("\n> ★ **Bookmark \(Self.clock(elapsed))**\(suffix)\n", to: fileURL)
        Log.meeting.info("★ Bookmark at \(Self.clock(elapsed))")
    }

    /// Append a Bookmarks jump-list of the timestamps captured this meeting.
    func appendBookmarks(to fileURL: URL) {
        guard !bookmarks.isEmpty else { return }
        let lines = bookmarks.map { b -> String in
            let suffix = b.note.isEmpty ? "" : " — \(b.note)"
            return "- ★ \(Self.clock(b.elapsed))\(suffix)"
        }
        append("\n# Bookmarks\n\n\(lines.joined(separator: "\n"))\n", to: fileURL)
        Log.meeting.info("★ Bookmarks appended")
    }

    private static func clock(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
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

    /// Append a Chapters section — a timestamped topic jump-list produced by the
    /// summarizer. `body` is already-formatted Markdown bullet lines.
    func appendChapters(_ body: String, to fileURL: URL) {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        append("\n# Chapters\n\n\(trimmed)\n", to: fileURL)
        Log.meeting.info("📖 Chapters appended")
    }

    /// Replace the front-matter `title:` with an AI-generated meeting title.
    /// No-op without front-matter or a title line (the on-disk filename is left
    /// unchanged, so Catalog links stay valid).
    static func setFrontMatterTitle(_ title: String, to fileURL: URL) {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        // Escape a colon-bearing title so it stays valid YAML.
        let safe = FrontMatter.yamlScalar(clean, quoteWhen: ":", quoteLeadingSpace: false)
        var replaced = false
        FrontMatter.mutate(fileURL: fileURL) { lines in
            replaced = FrontMatter.replaceLine(prefix: "title:", with: "title: \(safe)", in: &lines)
        }
        if replaced { Log.meeting.info("🏷 Meeting title set") }
    }

    /// Append an "Unanswered Questions" section (AI-extracted follow-up items).
    func appendUnansweredQuestions(_ body: String, to fileURL: URL) {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Normalise every bullet to an open checkbox (`- [ ] …`) so a question
        // can be ticked off (answered) from the Catalog or the note viewer,
        // exactly like an action item.
        let normalised = trimmed.components(separatedBy: "\n").map { raw -> String in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("- ") || line.hasPrefix("* ") else { return raw }
            var q = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            if q.hasPrefix("[ ] ") || q.lowercased().hasPrefix("[x] ") {
                q = String(q.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            }
            return "- [ ] \(q)"
        }.joined(separator: "\n")
        append("\n## Unanswered Questions\n\n\(normalised)\n", to: fileURL)
        Log.meeting.info("❓ Unanswered questions appended")
    }

    /// Count case-insensitive whole-word-ish occurrences of each watchlist term
    /// in the transcript. Returns only matched terms, most-mentioned first.
    static func mentionCounts(in transcript: String, terms: [String]) -> [(term: String, count: Int)] {
        guard !terms.isEmpty else { return [] }
        var out: [(String, Int)] = []
        for term in terms {
            let escaped = NSRegularExpression.escapedPattern(for: term)
            // Word boundaries when the term is alphanumeric; plain match otherwise.
            let isWord = term.allSatisfy { $0.isLetter || $0.isNumber }
            let pattern = isWord ? "\\b\(escaped)\\b" : escaped
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let n = re.numberOfMatches(in: transcript, range: NSRange(transcript.startIndex..., in: transcript))
            if n > 0 { out.append((term, n)) }
        }
        return out.sorted { $0.1 > $1.1 }
    }

    /// Append a "Mentions" section listing watchlist hits with counts.
    func appendMentions(_ matches: [(term: String, count: Int)], to fileURL: URL) {
        guard !matches.isEmpty else { return }
        let lines = matches.map { "- **\($0.term)** — \($0.count) mention\($0.count == 1 ? "" : "s")" }
            .joined(separator: "\n")
        append("\n## Mentions\n\n\(lines)\n", to: fileURL)
        Log.meeting.info("📡 Watchlist mentions appended")
    }

    /// Merge topic tags into the YAML front-matter `tags: [...]` line. No-op if
    /// the file has no front-matter (tags require it) or no new tags.
    static func addFrontMatterTags(_ tags: [String], to fileURL: URL) {
        let newTags = tags.filter { !$0.isEmpty }
        guard !newTags.isEmpty else { return }
        var updated = false
        FrontMatter.mutate(fileURL: fileURL) { lines in
            guard let i = lines.firstIndex(where: { $0.hasPrefix("tags:") }) else { return }
            // Parse existing "tags: [a, b]" and append any that are new.
            var merged = FrontMatter.tags(in: "---\n" + lines.joined(separator: "\n") + "\n---")
            for tag in newTags where !merged.contains(tag) { merged.append(tag) }
            lines[i] = "tags: [\(merged.joined(separator: ", "))]"
            updated = true
        }
        if updated { Log.meeting.info("🏷 Front-matter tags updated") }
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

        // Structured fields for Dataview / Notion-style filtering — inserted
        // after the tags line (and only when there is one, matching the tags mirror).
        var entries: [(key: String, value: String)] = []
        if !people.isEmpty { entries.append(("attendees", "[\(people.joined(separator: ", "))]")) }
        if let c = customer, !c.isEmpty { entries.append(("customer", c)) }
        if let p = project, !p.isEmpty { entries.append(("project", p)) }
        guard !entries.isEmpty else { return }

        var added = false
        FrontMatter.mutate(fileURL: fileURL) { lines in
            guard lines.contains(where: { $0.hasPrefix("tags:") }) else { return }
            let before = lines.count
            FrontMatter.insertFields(entries, after: ["tags:"], in: &lines)
            added = lines.count != before
        }
        if added { Log.meeting.info("🏷 Front-matter entities added") }
    }

    /// Insert `gw_<key>: value` fields into the front-matter, after the tags
    /// line (or after `title:` when there's no tags line). Skips keys already
    /// present. Values with YAML-significant characters are quoted. No-op
    /// without front-matter.
    static func addFrontMatterFields(_ pairs: [(key: String, value: String)], to fileURL: URL) {
        let clean = pairs.filter { !$0.value.isEmpty }
        guard !clean.isEmpty else { return }
        // Each field as `gw_<key>: <yaml-quoted value>`, inserted after tags:,
        // else after title:, else right under the opening --- (insertFields'
        // default). Keys already present are skipped.
        let entries = clean.map { (key: "gw_\($0.key)", value: FrontMatter.yamlScalar($0.value)) }
        var added = false
        FrontMatter.mutate(fileURL: fileURL) { lines in
            let before = lines.count
            FrontMatter.insertFields(entries, after: ["tags:", "title:"], in: &lines)
            added = lines.count != before
        }
        if added { Log.meeting.info("🏷 Front-matter key fields added") }
    }

    /// Append a "## Key Details" section rendering the extracted fields as a
    /// readable bullet list. No-op when there's nothing to show.
    func appendKeyDetails(_ pairs: [(label: String, value: String)], to fileURL: URL) {
        let rows = pairs.filter { !$0.value.isEmpty }
        guard !rows.isEmpty else { return }
        let body = rows.map { "- **\($0.label):** \($0.value)" }.joined(separator: "\n")
        append("\n## Key Details\n\n\(body)\n", to: fileURL)
        Log.meeting.info("🔑 Key Details appended")
    }

    /// Mirror categorical key fields into `tags:` as `<key>-<value>` tokens so
    /// they're filterable with the Catalog's existing tag filter.
    static func mirrorFieldsToTags(_ pairs: [(key: String, value: String)], to fileURL: URL) {
        let tokens = pairs
            .filter { !$0.value.isEmpty }
            .map { slug("\($0.key)-\($0.value)") }
            .filter { !$0.isEmpty }
        addFrontMatterTags(tokens, to: fileURL)
    }

    /// Full text of a notes file (for summarization).
    func transcriptText(of fileURL: URL) -> String? {
        fileURL.readText()
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
