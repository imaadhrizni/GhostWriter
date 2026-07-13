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
}
