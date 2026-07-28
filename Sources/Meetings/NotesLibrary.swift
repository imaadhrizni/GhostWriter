import Foundation

// MARK: - Notes folder helpers
//
// Shared data layer over the meeting-notes folder (file listing, text/semantic
// search, cross-meeting excerpt retrieval, action-item parsing) that the
// Catalog and other features build on.

enum NotesLibrary {

    struct MeetingFile: Identifiable, Hashable {
        let url: URL
        var id: URL { url }

        /// "yyyy-MM-dd_HH-mm-ss" from the filename.
        private var stamp: String {
            url.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "Meeting_", with: "")
        }
        /// "2026-07-03" — grouping key matching the folder hierarchy.
        var day: String { String(stamp.prefix(10)) }
        /// "14:30:22"
        var time: String {
            stamp.count > 11
                ? String(stamp.dropFirst(11)).replacingOccurrences(of: "-", with: ":")
                : stamp
        }
        var displayName: String { "\(DateDisplay.day(day)) · \(time)" }
    }

    static func meetingFiles(limit: Int = 50) -> [MeetingFile] {
        MeetingNotesWriter.allMeetingFiles(under: AppSettings.shared.notesFolder)
            .prefix(limit)
            .map(MeetingFile.init)
    }

    struct SearchHit: Identifiable {
        let id = UUID()
        let file: MeetingFile
        let line: String
    }

    /// Whether the meaning (embedding) half of retrieval is available. Lexical
    /// retrieval runs regardless, so callers no longer gate on this — it's only
    /// used to label the UI ("Meaning" search) honestly.
    static var semanticAvailable: Bool { SemanticIndex.shared.isAvailable }

    /// Hybrid search: rank note chunks by blended meaning + keyword relevance,
    /// one hit per meeting (its best-matching chunk). Works even without an
    /// embedding model (lexical only).
    static func semanticSearch(_ query: String, maxHits: Int = 40,
                               maxFiles: Int = AppSettings.shared.searchDepth) async -> [SearchHit] {
        let files = meetingFiles(limit: maxFiles)
        let byURL = Dictionary(files.map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
        let results = await SemanticIndex.shared.query(query, files: files.map(\.url), topK: maxHits * 2)

        var seen = Set<URL>()
        var hits: [SearchHit] = []
        for r in results where r.score > 0.1 {   // drop weak matches
            guard let file = byURL[r.url], !seen.contains(r.url) else { continue }
            seen.insert(r.url)
            hits.append(SearchHit(file: file, line: r.text))
            if hits.count >= maxHits { break }
        }
        return hits
    }

    /// Semantic retrieval for cross-meeting Ask: the top chunks by meaning,
    /// grouped per meeting and labeled so the model can cite sources.
    static func semanticExcerpts(for query: String,
                                 maxFiles: Int = AppSettings.shared.searchDepth,
                                 maxChars: Int = 20_000, topK: Int = 24) async -> ExcerptResult {
        await semanticExcerpts(for: query, files: meetingFiles(limit: maxFiles), maxChars: maxChars, topK: topK)
    }

    /// Semantic retrieval scoped to an explicit set of files (used by the
    /// Catalog's filter-scoped Ask).
    static func semanticExcerpts(for query: String, files: [MeetingFile],
                                 maxChars: Int = 20_000, topK: Int = 24) async -> ExcerptResult {
        let byURL = Dictionary(files.map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
        let results = await SemanticIndex.shared.query(query, files: files.map(\.url), topK: topK)
        guard !results.isEmpty else { return ExcerptResult(text: "", sources: [], citations: []) }

        // Group chunks by meeting, preserving descending relevance. Keep the
        // top-scoring chunk + matched terms per meeting for a cited snippet.
        var order: [URL] = []
        var byFile: [URL: [String]] = [:]
        var best: [URL: (snippet: String, terms: [String])] = [:]
        for r in results where r.score > 0.08 {
            if byFile[r.url] == nil { order.append(r.url); best[r.url] = (r.text, r.matched) }
            byFile[r.url, default: []].append(r.text)
        }

        var out = ""
        var sources: [MeetingFile] = []
        var citations: [ExcerptResult.Citation] = []
        for url in order {
            guard let file = byURL[url] else { continue }
            var block = "\n=== Meeting \(file.displayName) ===\n"
            for chunk in byFile[url] ?? [] { block += chunk + "\n" }
            if out.count + block.count > maxChars { break }
            out += block
            sources.append(file)
            let b = best[url] ?? (byFile[url]?.first ?? "", [])
            citations.append(ExcerptResult.Citation(file: file, snippet: b.snippet, terms: b.terms))
        }
        return ExcerptResult(text: out, sources: sources, citations: citations)
    }

    /// Agentic retrieval: run several planned queries and merge their excerpts
    /// into one context, deduping meetings by URL (first query to surface a
    /// meeting keeps its citation) and staying under `maxChars`. Used by Ask's
    /// agentic path so evidence is gathered from several angles at once. `files`
    /// nil = the whole archive.
    static func semanticExcerpts(forQueries queries: [String], files: [MeetingFile]?,
                                 maxChars: Int = 20_000, topK: Int = 16) async -> ExcerptResult {
        let unique = Array(NSOrderedSet(array: queries.filter { !$0.isEmpty })) as? [String] ?? queries
        guard !unique.isEmpty else { return ExcerptResult(text: "", sources: [], citations: []) }

        // Per-query retrieval, each capped so no single angle floods the budget.
        let perQueryChars = max(4_000, maxChars / unique.count)
        var text = ""
        var sources: [MeetingFile] = []
        var citations: [ExcerptResult.Citation] = []
        var seenBlocks = Set<String>()
        var seenSources = Set<URL>()

        for query in unique {
            let r = files == nil
                ? await semanticExcerpts(for: query, maxChars: perQueryChars, topK: topK)
                : await semanticExcerpts(for: query, files: files!, maxChars: perQueryChars, topK: topK)
            // Append per-meeting blocks we haven't already included.
            for block in r.text.components(separatedBy: "\n=== Meeting ") {
                let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let normalized = "=== Meeting " + trimmed
                guard seenBlocks.insert(normalized).inserted else { continue }
                if text.count + normalized.count > maxChars { break }
                text += "\n" + normalized + "\n"
            }
            for c in r.citations where seenSources.insert(c.file.url).inserted {
                sources.append(c.file); citations.append(c)
            }
        }
        return ExcerptResult(text: text, sources: sources, citations: citations)
    }

    /// Excerpts retrieved for Ask, plus the meetings they came from.
    struct ExcerptResult {
        let text: String
        let sources: [MeetingFile]   // meetings the excerpts came from, newest first
        /// Per-source best snippet + matched query terms, for a cited preview.
        var citations: [Citation] = []
        struct Citation: Identifiable {
            let id = UUID()
            let file: MeetingFile
            let snippet: String
            let terms: [String]
        }
    }

    struct ActionItem: Identifiable {
        let id = UUID()
        let file: MeetingFile
        /// Full item text (everything after the checkbox), preserved verbatim so
        /// toggling can rewrite the line without losing the owner/due annotations.
        let text: String
        let done: Bool
        /// The exact line in the file — used to toggle done state in place.
        let rawLine: String

        /// Assignee, from a "@owner" token when the summary identified one.
        var owner: String? {
            guard let m = ActionItem.ownerRegex.firstMatch(
                in: text, range: NSRange(text.startIndex..., in: text)),
                let r = Range(m.range(at: 1), in: text) else { return nil }
            return String(text[r])
        }

        /// Due date, from a "(due: …)" annotation when the summary stated one.
        var due: String? {
            guard let m = ActionItem.dueRegex.firstMatch(
                in: text, range: NSRange(text.startIndex..., in: text)),
                let r = Range(m.range(at: 1), in: text) else { return nil }
            return String(text[r]).trimmingCharacters(in: .whitespaces)
        }

        /// The action alone, with the "@owner" / "(due: …)" chips and any
        /// trailing "—" separator removed — for a clean row and Reminders title.
        var displayText: String {
            var s = text
            s = ActionItem.dueRegex.stringByReplacingMatches(
                in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
            s = ActionItem.ownerRegex.stringByReplacingMatches(
                in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
            s = s.trimmingCharacters(in: .whitespaces)
            while s.hasSuffix("—") || s.hasSuffix("-") || s.hasSuffix(",") {
                s = String(s.dropLast()).trimmingCharacters(in: .whitespaces)
            }
            return s.isEmpty ? text : s
        }

        // Owner is only recognized in the trailing "— @owner" position the
        // summary emits, so an @mention or email inside the action text isn't
        // mistaken for the assignee.
        private static let ownerRegex =
            try! NSRegularExpression(pattern: "[—–-]\\s*@([\\w][\\w.'-]*)")
        private static let dueRegex =
            try! NSRegularExpression(pattern: "\\(due:\\s*([^)]*)\\)",
                                     options: [.caseInsensitive])
    }

    /// Flip an item's checkbox in its notes file.
    @discardableResult
    static func toggleDone(_ item: ActionItem) -> Bool {
        setCheckbox(rawLine: item.rawLine, text: item.text, done: !item.done, inFile: item.file.url)
    }

    /// Rewrite a single checkbox bullet — located by its exact trimmed source
    /// line — to `done`. Rebuilds the line from clean parts (indent + bullet +
    /// one checkbox + text), so it's idempotent, repairs any earlier duplicated
    /// "[x] [x]" tokens, and upgrades a legacy plain `-`/`*` bullet to a
    /// checkbox. Returns false when the file can't be read/written or the line
    /// is gone (edited elsewhere). Shared by action items and open questions.
    @discardableResult
    static func setCheckbox(rawLine: String, text: String, done: Bool, inFile url: URL) -> Bool {
        guard let content = url.readText() else { return false }
        var lines = content.components(separatedBy: "\n")
        guard let idx = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == rawLine
        }) else { return false }
        let indent = lines[idx].prefix(while: { $0 == " " || $0 == "\t" })
        let bullet = rawLine.hasPrefix("*") ? "*" : "-"
        lines[idx] = "\(indent)\(bullet) [\(done ? "x" : " ")] \(text)"
        do {
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            Log.app.error("❌ Could not update checkbox line: \(error.localizedDescription)")
            return false
        }
    }

    /// One question under a note's "## Unanswered Questions" heading. `done`
    /// reflects a `- [x]` checkbox; legacy plain `-`/`*` bullets read as open.
    /// `rawLine` is the trimmed source line, used to locate it for a toggle.
    struct OpenQuestion: Identifiable {
        let id = UUID()
        let text: String
        let done: Bool
        let rawLine: String
    }

    /// Parse the questions under a note's questions section(s), preserving each
    /// one's answered state. Accepts both the canonical `## Open Questions`
    /// heading and the legacy `## Unanswered Questions` (older notes / the
    /// summary's structured-extraction block); if a note carries both, their
    /// items are merged and deduped case-insensitively. One shared
    /// implementation for the Catalog dashboard card and the Open Questions list.
    static func openQuestions(in text: String) -> [OpenQuestion] {
        var out: [OpenQuestion] = []
        var seen = Set<String>()
        var inSection = false
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") || line.hasPrefix("# ") {
                let h = line.lowercased()
                inSection = (h == "## open questions" || h == "## unanswered questions")
                continue
            }
            guard inSection, line.hasPrefix("- ") || line.hasPrefix("* ") else { continue }
            var body = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            var done = false
            if body.hasPrefix("[ ] ") {
                body = String(body.dropFirst(4))
            } else if body.lowercased().hasPrefix("[x] ") {
                done = true; body = String(body.dropFirst(4))
            }
            body = body.trimmingCharacters(in: .whitespaces)
            guard !body.isEmpty, seen.insert(body.lowercased()).inserted else { continue }
            out.append(OpenQuestion(text: body, done: done, rawLine: line))
        }
        return out
    }

    /// Action items parsed from a single notes file — bullets under the
    /// "## Action Items" heading. Used by the Catalog note editor.
    static func actionItems(inFile url: URL) -> [ActionItem] {
        guard let content = url.readText() else { return [] }
        let file = MeetingFile(url: url)
        var items: [ActionItem] = [], inSection = false
        for rawLine in content.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.lowercased().hasPrefix("## action items") { inSection = true; continue }
            if inSection {
                if line.hasPrefix("#") { inSection = false; continue }
                if line.hasPrefix("-") || line.hasPrefix("*") {
                    var text = line.dropFirst().trimmingCharacters(in: .whitespaces)
                    var done = false
                    while text.hasPrefix("[ ]") || text.lowercased().hasPrefix("[x]") {
                        if text.lowercased().hasPrefix("[x]") { done = true }
                        text = text.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    }
                    // Skip "none" placeholders the AI writes when there are no
                    // action items (e.g. "- _None_", "- N/A", "- —").
                    if !text.isEmpty, !Self.isNonePlaceholder(String(text)) {
                        items.append(ActionItem(file: file, text: String(text), done: done, rawLine: line))
                    }
                }
            }
        }
        return items
    }

    /// True when a bullet is a "no items" placeholder rather than a real action
    /// — stripped of markdown emphasis/punctuation it reads as none / n/a / etc.
    static func isNonePlaceholder(_ s: String) -> Bool {
        let stripped = s
            .trimmingCharacters(in: CharacterSet(charactersIn: "_*`~ ()—–-."))
            .lowercased()
        return ["", "none", "n/a", "na", "nil", "nothing",
                "no action items", "no items", "none."].contains(stripped)
    }
}

