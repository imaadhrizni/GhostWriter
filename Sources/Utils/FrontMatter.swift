import Foundation

// MARK: - YAML front-matter helpers
//
// Notes and dictations start with an optional Obsidian-style YAML front-matter
// block:
//
//     ---
//     title: …
//     tags: [meeting, ghostwriter]
//     ---
//
// Several call sites need to separate that metadata from the note body. This is
// the one shared implementation; ad-hoc re-strips elsewhere should route here.

enum FrontMatter {

    /// Split `text` into its leading front-matter (without the `---` fences,
    /// or nil when absent) and the remaining body. Line-based so it matches how
    /// the writer emits the block.
    static func split(_ text: String) -> (frontMatter: String?, body: String) {
        guard text.hasPrefix("---") else { return (nil, text) }
        let lines = text.components(separatedBy: "\n")
        guard let close = lines.dropFirst().firstIndex(of: "---") else { return (nil, text) }
        let fm = lines[1..<close].joined(separator: "\n")
        let body = lines[(close + 1)...].joined(separator: "\n")
        return (fm.isEmpty ? nil : fm, body)
    }

    /// The note body with any leading front-matter removed.
    static func body(_ text: String) -> String { split(text).body }

    /// The value of a scalar front-matter field (e.g. `gw_meeting_type`), or nil
    /// when the field is absent. Only scans the front-matter block.
    static func field(_ key: String, in text: String) -> String? {
        guard let fm = split(text).frontMatter else { return nil }
        for line in fm.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("\(key):") {
                return String(trimmed.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// The note's `title:` field, stripped of surrounding quotes/whitespace, or
    /// nil when absent/empty. Callers supply their own fallback (filename, etc.).
    static func title(in text: String) -> String? {
        let t = field("title", in: text)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        return (t?.isEmpty == false) ? t : nil
    }

    /// Parse a YAML `tags: [a, b, c]` line from the front-matter into trimmed,
    /// non-empty values. Empty when there's no front-matter or no tags line.
    static func tags(in text: String) -> [String] {
        guard let value = field("tags", in: text) else { return [] }
        return value
            .drop(while: { $0 != "[" }).dropFirst()
            .prefix(while: { $0 != "]" })
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Mutation

    /// Load `fileURL`, hand `transform` the front-matter's **content lines**
    /// (those between the `---` fences, exclusive), and write the file back
    /// atomically. The opening/closing fences and the body are preserved
    /// verbatim. Returns `false` (no write) when the file can't be read or has
    /// no front-matter block. The single shared load/split/rejoin/write path for
    /// the note-writer's front-matter edits.
    @discardableResult
    static func mutate(fileURL: URL, _ transform: (inout [String]) -> Void) -> Bool {
        guard var content = fileURL.readText(), content.hasPrefix("---") else { return false }
        var lines = content.components(separatedBy: "\n")
        guard let close = lines.dropFirst().firstIndex(of: "---") else { return false }
        var fm = Array(lines[1..<close])
        transform(&fm)
        lines.replaceSubrange(1..<close, with: fm)
        content = lines.joined(separator: "\n")
        try? content.write(to: fileURL, atomically: true, encoding: .utf8)
        return true
    }

    /// Replace the first line beginning with `prefix` (e.g. `"title:"`) with
    /// `newLine`. Returns `false` when no such line exists.
    @discardableResult
    static func replaceLine(prefix: String, with newLine: String, in lines: inout [String]) -> Bool {
        guard let i = lines.firstIndex(where: { $0.hasPrefix(prefix) }) else { return false }
        lines[i] = newLine
        return true
    }

    /// Insert `key: value` lines after the first line matching one of
    /// `afterPrefixes` (tried in order; falls back to the top of the block).
    /// Entries whose `key:` already exists are skipped.
    static func insertFields(_ entries: [(key: String, value: String)],
                             after afterPrefixes: [String], in lines: inout [String]) {
        let toInsert = entries.compactMap { e in
            lines.contains(where: { $0.hasPrefix("\(e.key):") }) ? nil : "\(e.key): \(e.value)"
        }
        guard !toInsert.isEmpty else { return }
        var at = 0
        for prefix in afterPrefixes {
            if let i = lines.firstIndex(where: { $0.hasPrefix(prefix) }) { at = i + 1; break }
        }
        lines.insert(contentsOf: toInsert, at: at)
    }

    /// Render a scalar value for YAML, quoting it when it contains a
    /// significant character (embedded `"` become `'`). `quoteWhen` is the set of
    /// characters that force quoting; `quoteLeadingSpace` also quotes a value
    /// that starts with a space.
    static func yamlScalar(_ s: String, quoteWhen: String = ":#[]{}",
                           quoteLeadingSpace: Bool = true) -> String {
        let needs = s.contains(where: { quoteWhen.contains($0) })
            || (quoteLeadingSpace && s.hasPrefix(" "))
        return needs ? "\"\(s.replacingOccurrences(of: "\"", with: "'"))\"" : s
    }
}
