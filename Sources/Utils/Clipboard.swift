import AppKit

// MARK: - Pasteboard helpers
//
// One shared implementation of the two clipboard writes used across the app:
// a plain-string copy, and a Markdown copy that lands as both rich text (RTF)
// and a clean plain-text fallback — so pasting into Mail / Gmail / docs keeps
// headings, bold, and bullets, while a code field still gets clean text.
// Callers set their own user-facing status strings.

enum Clipboard {

    /// Replace the pasteboard with `text` as a plain string.
    static func plain(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// Replace the pasteboard with `markdown` rendered to RTF plus a
    /// markdown-stripped plain-text fallback. Falls back to a plain copy of the
    /// raw Markdown if it can't be parsed.
    static func markdown(_ markdown: String) {
        let pb = NSPasteboard.general
        guard let attr = try? NSAttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .full,
                           failurePolicy: .returnPartiallyParsedIfPossible)) else {
            plain(markdown)
            return
        }
        pb.clearContents()
        pb.declareTypes([.rtf, .string], owner: nil)
        if let rtf = attr.rtf(from: NSRange(location: 0, length: attr.length),
                              documentAttributes: [:]) {
            pb.setData(rtf, forType: .rtf)
        }
        pb.setString(attr.string, forType: .string)
    }
}
