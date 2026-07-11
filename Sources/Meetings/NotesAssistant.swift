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

    /// Flip an item's checkbox in its notes file. Line-based: finds the
    /// item's exact line (ignoring indentation), rewrites just that line.
    /// Returns false when the line is gone (file edited elsewhere).
    @discardableResult
    static func toggleDone(_ item: ActionItem) -> Bool {
        guard let content = try? String(contentsOf: item.file.url, encoding: .utf8) else { return false }
        var lines = content.components(separatedBy: "\n")
        guard let idx = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == item.rawLine
        }) else { return false }

        // Rebuild the line from clean parts (bullet + one checkbox + text) —
        // idempotent, and repairs any earlier duplicated "[x] [x]" tokens.
        let indent = lines[idx].prefix(while: { $0 == " " || $0 == "\t" })
        let bullet = item.rawLine.hasPrefix("*") ? "*" : "-"
        lines[idx] = "\(indent)\(bullet) [\(item.done ? " " : "x")] \(item.text)"
        do {
            try lines.joined(separator: "\n").write(to: item.file.url, atomically: true, encoding: .utf8)
            return true
        } catch {
            Log.app.error("❌ Could not update action item: \(error.localizedDescription)")
            return false
        }
    }

    /// Action items parsed from a single notes file — bullets under the
    /// "## Action Items" heading. Used by the Catalog note editor.
    static func actionItems(inFile url: URL) -> [ActionItem] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
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
                    if !text.isEmpty { items.append(ActionItem(file: file, text: text, done: done, rawLine: line)) }
                }
            }
        }
        return items
    }
}

