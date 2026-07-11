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
}
