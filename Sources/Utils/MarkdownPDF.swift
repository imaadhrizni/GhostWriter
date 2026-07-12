import AppKit
import CoreText

// MARK: - Markdown → PDF
//
// Renders a note's Markdown into a clean, paginated PDF (US Letter). Deliberately
// small: we handle the subset the app actually emits — headings, bullet/checkbox
// lists, blank-line spacing, and inline **bold** — rather than pulling in a full
// Markdown engine. YAML front-matter (--- … ---) is skipped so exports stay clean.
//
// All ink is set to explicit dark colors (never the dynamic textColor, which is
// white in dark mode and would render invisibly on the PDF's white page).

enum MarkdownPDF {

    private static let pageSize = CGSize(width: 612, height: 792)   // US Letter, 72 dpi
    private static let margin: CGFloat = 56                         // ~0.78"

    // Explicit print colors — independent of the app's light/dark appearance.
    private static let inkBody     = NSColor(calibratedWhite: 0.12, alpha: 1)
    private static let inkHeading  = NSColor(calibratedWhite: 0.06, alpha: 1)
    private static let inkMuted    = NSColor(calibratedWhite: 0.45, alpha: 1)

    /// Paginated PDF data for the given Markdown, or nil if a PDF context
    /// couldn't be created.
    static func data(from markdown: String, title: String) -> Data? {
        let attr = attributed(from: markdown)

        let textRect = CGRect(
            x: margin, y: margin,
            width: pageSize.width - margin * 2,
            height: pageSize.height - margin * 2)
        let framesetter = CTFramesetterCreateWithAttributedString(attr as CFAttributedString)
        let path = CGPath(rect: textRect, transform: nil)

        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return nil }
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }

        var start = 0
        var page = 0
        let total = attr.length
        // Lay out one frame per page; CTFrameGetVisibleStringRange tells us how
        // much fit so the next page continues where this one stopped.
        while start < total {
            ctx.beginPDFPage(nil)
            page += 1
            let frame = CTFramesetterCreateFrame(
                framesetter, CFRangeMake(start, 0), path, nil)
            CTFrameDraw(frame, ctx)
            drawFooter(ctx, page: page)
            let visible = CTFrameGetVisibleStringRange(frame)
            ctx.endPDFPage()
            if visible.length == 0 { break }   // nothing fit — avoid an infinite loop
            start += visible.length
        }
        ctx.closePDF()
        return data as Data
    }

    /// Centered page number in the bottom margin.
    private static func drawFooter(_ ctx: CGContext, page: Int) {
        let s = NSAttributedString(string: "\(page)", attributes: [
            .font: NSFont.systemFont(ofSize: 9),
            .foregroundColor: inkMuted,
        ])
        let line = CTLineCreateWithAttributedString(s)
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        ctx.textPosition = CGPoint(x: (pageSize.width - CGFloat(width)) / 2, y: margin * 0.55)
        CTLineDraw(line, ctx)
    }

    // MARK: - Markdown → attributed string

    private static func attributed(from markdown: String) -> NSAttributedString {
        let out = NSMutableAttributedString()

        // Drop the leading YAML front-matter, then render the body.
        for rawLine in FrontMatter.body(markdown).components(separatedBy: "\n") {
            let line = rawLine
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                out.append(NSAttributedString(string: "\n", attributes: [.font: gap]))
                continue
            }

            // A "---" / "***" line inside the body is a horizontal rule.
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                appendRule(to: out); continue
            }

            if trimmed.hasPrefix("### ") {
                append(String(trimmed.dropFirst(4)), font: h3Font, color: inkHeading,
                       spacingBefore: 10, spacingAfter: 3, to: out)
            } else if trimmed.hasPrefix("## ") {
                append(String(trimmed.dropFirst(3)), font: h2Font, color: inkHeading,
                       spacingBefore: 16, spacingAfter: 5, to: out)
            } else if trimmed.hasPrefix("# ") {
                append(String(trimmed.dropFirst(2)), font: h1Font, color: inkHeading,
                       spacingBefore: 2, spacingAfter: 8, to: out)
            } else if let bullet = bulletContent(trimmed) {
                append(bullet.text, font: bodyFont, color: inkBody,
                       spacingAfter: 3, indent: 20, hanging: 20,
                       marker: bullet.marker, to: out)
            } else {
                append(trimmed, font: bodyFont, color: inkBody, spacingAfter: 6, to: out)
            }
        }
        return out
    }

    /// A thin horizontal rule drawn with an underlined run of spaces.
    private static func appendRule(to out: NSMutableAttributedString) {
        let para = NSMutableParagraphStyle()
        para.paragraphSpacingBefore = 6
        para.paragraphSpacing = 8
        out.append(NSAttributedString(string: "\u{00A0}\n", attributes: [
            .font: NSFont.systemFont(ofSize: 4),
            .strikethroughStyle: NSUnderlineStyle.single.rawValue,
            .strikethroughColor: NSColor(calibratedWhite: 0.8, alpha: 1),
            .paragraphStyle: para,
        ]))
    }

    /// Recognize "- item" / "* item" incl. "- [ ] item" / "- [x] item" checkboxes.
    /// The returned marker is the glyph to hang in the bullet's left indent.
    private static func bulletContent(_ line: String) -> (text: String, marker: String)? {
        guard line.hasPrefix("- ") || line.hasPrefix("* ") else { return nil }
        var rest = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        var marker = "•  "
        if rest.hasPrefix("[ ]") { marker = "☐  "; rest = String(rest.dropFirst(3)) }
        else if rest.lowercased().hasPrefix("[x]") { marker = "☑  "; rest = String(rest.dropFirst(3)) }
        return (rest.trimmingCharacters(in: .whitespaces), marker)
    }

    /// Append one paragraph, parsing inline **bold**. `marker` (for list items)
    /// is placed in the hanging indent so wrapped lines align under the text.
    private static func append(_ text: String, font: NSFont, color: NSColor,
                               spacingBefore: CGFloat = 0, spacingAfter: CGFloat = 0,
                               indent: CGFloat = 0, hanging: CGFloat = 0,
                               marker: String? = nil,
                               to out: NSMutableAttributedString) {
        let para = NSMutableParagraphStyle()
        para.paragraphSpacing = spacingAfter
        para.paragraphSpacingBefore = spacingBefore
        para.firstLineHeadIndent = indent - hanging
        para.headIndent = indent
        para.lineSpacing = 2.5

        if let marker {
            out.append(NSAttributedString(string: marker, attributes: [
                .font: font, .foregroundColor: color, .paragraphStyle: para,
            ]))
        }
        appendInline(text, font: font, color: color, paragraph: para, to: out)
        out.append(NSAttributedString(string: "\n", attributes: [.font: font, .paragraphStyle: para]))
    }

    /// Split on "**" toggling bold; everything else uses the base font.
    private static func appendInline(_ text: String, font: NSFont, color: NSColor,
                                     paragraph: NSParagraphStyle,
                                     to out: NSMutableAttributedString) {
        let parts = text.components(separatedBy: "**")
        for (i, part) in parts.enumerated() where !part.isEmpty {
            let bold = i % 2 == 1   // odd segments sit between ** markers
            let f = bold ? NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) : font
            out.append(NSAttributedString(string: part, attributes: [
                .font: f,
                .paragraphStyle: paragraph,
                .foregroundColor: color,
            ]))
        }
    }

    // MARK: - Fonts

    private static let bodyFont = NSFont.systemFont(ofSize: 11)
    private static let h1Font   = NSFont.systemFont(ofSize: 22, weight: .bold)
    private static let h2Font   = NSFont.systemFont(ofSize: 15, weight: .semibold)
    private static let h3Font   = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
    private static let gap      = NSFont.systemFont(ofSize: 6)   // blank-line height
}
