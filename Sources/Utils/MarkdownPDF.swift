import AppKit
import CoreText

// MARK: - Markdown → PDF
//
// Renders a note's Markdown into a clean, paginated PDF (US Letter). Deliberately
// small: we handle the subset the app actually emits — headings, bullet/checkbox
// lists, blank-line spacing, and inline **bold** — rather than pulling in a full
// Markdown engine. The document opens with a title block (title + date / org /
// opportunity pulled from the YAML front-matter) and, when the note has two or
// more headings, an auto-generated Table of Contents with page numbers.
//
// All ink is set to explicit dark colors (never the dynamic textColor, which is
// white in dark mode and would render invisibly on the PDF's white page).

enum MarkdownPDF {

    private static let pageSize = CGSize(width: 612, height: 792)   // US Letter, 72 dpi
    private static let margin: CGFloat = 56                         // ~0.78"

    // Explicit print colors — independent of the app's light/dark appearance.
    // Palette echoes the GhostWriter app icon: a deep-navy ground with a
    // luminous cyan glow. Headings take the navy; rules/links take the cyan.
    private static let inkBody     = NSColor(calibratedWhite: 0.12, alpha: 1)
    private static let inkHeading  = NSColor(calibratedRed: 0.055, green: 0.078, blue: 0.145, alpha: 1) // icon navy
    private static let inkMuted    = NSColor(calibratedRed: 0.34, green: 0.40, blue: 0.50, alpha: 1)    // navy-tinted grey
    private static let inkRule     = NSColor(calibratedRed: 0.80, green: 0.85, blue: 0.90, alpha: 1)    // cool hairline
    private static let accent      = NSColor(calibratedRed: 0.05, green: 0.62, blue: 0.80, alpha: 1)    // icon cyan (print-safe)

    private static var textWidth: CGFloat { pageSize.width - margin * 2 }

    /// One proof-of-concept criterion for the POC section (resolved from the
    /// Catalog by the caller, since criteria live on the opportunity).
    struct POCItem { let text: String; let status: String }

    /// Paginated PDF data for the given Markdown, or nil if a PDF context
    /// couldn't be created. `org` / `opportunity` / `project` / `poc` come from
    /// the Catalog (resolved as one chain so they stay consistent) and override
    /// the note's own front-matter for those fields.
    static func data(from markdown: String, title: String,
                     org: String? = nil, opportunity: String? = nil,
                     project: String? = nil, poc: [POCItem] = []) -> Data? {
        let body = FrontMatter.body(markdown)
        // Prefer the note's own front-matter title (the AI-generated one) over
        // the raw filename the caller passes.
        let fmTitle = FrontMatter.field("title", in: markdown)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        let displayTitle = (fmTitle?.isEmpty == false) ? fmTitle! : title

        // Fixed prefix (never affected by TOC paging): title + Properties box.
        let prefix = NSMutableAttributedString()
        prefix.append(buildHeader(title: displayTitle))
        prefix.append(buildProperties(markdown, org: org, opportunity: opportunity, project: project))

        // Content = body, then the POC section as a trailing section so it reads
        // last and earns its own Table-of-Contents entry.
        let (content, headings) = buildContent(body: body, poc: poc)

        let textRect = CGRect(x: margin, y: margin, width: textWidth, height: pageSize.height - margin * 2)
        let path = CGPath(rect: textRect, transform: nil)

        // Compose the final document, resolving TOC page numbers with a first
        // layout pass when a table of contents is warranted (≥ 2 headings).
        let final = NSMutableAttributedString()
        final.append(prefix)
        // Absolute char locations used to wire up clickable links: each TOC row
        // → the heading it names.
        var headingAbs: [Int] = []      // heading start char in `final`
        var tocEntryAbs: [CFRange] = []  // TOC row char range in `final`

        if headings.count >= 2 {
            // Pass 1: lay out with placeholder page numbers to discover which
            // page each heading lands on. The TOC's line count doesn't depend on
            // the numbers, so pagination is identical in pass 2 — the numbers we
            // compute here stay correct.
            let (tocDummy, _) = buildTOC(headings.map { ($0.level, $0.text) }, pages: headings.map { _ in 0 })
            let probe = NSMutableAttributedString()
            probe.append(prefix); probe.append(tocDummy); probe.append(content)
            let probeRanges = pageRanges(for: probe, path: path)
            let base = prefix.length + tocDummy.length
            let pages = headings.map { pageIndex(for: base + $0.loc, in: probeRanges) + 1 }

            let (tocReal, tocRanges) = buildTOC(headings.map { ($0.level, $0.text) }, pages: pages)
            final.append(tocReal)
            let tocBase = prefix.length
            let contentBase = prefix.length + tocReal.length
            tocEntryAbs = tocRanges.map { CFRangeMake(tocBase + $0.location, $0.length) }
            headingAbs = headings.map { contentBase + $0.loc }
        }
        final.append(content)

        // Final pagination + draw.
        let ranges = pageRanges(for: final, path: path)
        let framesetter = CTFramesetterCreateWithAttributedString(final as CFAttributedString)

        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return nil }
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }

        let textRectForLinks = textRect
        let total = max(ranges.count, 1)
        for (i, range) in ranges.enumerated() {
            ctx.beginPDFPage(nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(range.location, 0), path, nil)
            CTFrameDraw(frame, ctx)
            drawLinks(ctx, frame: frame, textRect: textRectForLinks,
                      headingAbs: headingAbs, tocEntryAbs: tocEntryAbs)
            drawFooter(ctx, page: i + 1, total: total, title: title)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return data as Data
    }

    /// Wire up the clickable Table of Contents: on each page, place a named
    /// destination at any heading found there, and a link rect over any TOC row
    /// found there (pointing at the destination for the heading it names). PDF
    /// resolves destinations by name at close, so order across pages is fine.
    private static func drawLinks(_ ctx: CGContext, frame: CTFrame, textRect: CGRect,
                                  headingAbs: [Int], tocEntryAbs: [CFRange]) {
        guard !headingAbs.isEmpty else { return }
        let lines = CTFrameGetLines(frame) as? [CTLine] ?? []
        guard !lines.isEmpty else { return }
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRangeMake(0, 0), &origins)

        for (li, line) in lines.enumerated() {
            let lr = CTLineGetStringRange(line)
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
            let oy = textRect.minY + origins[li].y
            let lineStart = lr.location, lineEnd = lr.location + lr.length

            // Destination at each heading's line (top of the line).
            for (hi, loc) in headingAbs.enumerated() where loc >= lineStart && loc < lineEnd {
                ctx.addDestination("gwsec\(hi)" as CFString, at: CGPoint(x: textRect.minX, y: oy + ascent + 6))
            }
            // Link rect over each TOC row (widened to the full text column so the
            // whole row — including the leader and page number — is clickable).
            for (ti, r) in tocEntryAbs.enumerated()
            where r.location < lineEnd && (r.location + r.length) > lineStart {
                let rect = CGRect(x: textRect.minX, y: oy - descent - 1,
                                  width: max(width, textRect.width), height: ascent + descent + 2)
                ctx.setDestination("gwsec\(ti)" as CFString, for: rect)
            }
        }
    }

    // MARK: - Pagination helpers

    /// The character range that fits on each page, laying out `attr` in `path`.
    private static func pageRanges(for attr: NSAttributedString, path: CGPath) -> [CFRange] {
        let fs = CTFramesetterCreateWithAttributedString(attr as CFAttributedString)
        var ranges: [CFRange] = []
        var start = 0
        let total = attr.length
        while start < total {
            let frame = CTFramesetterCreateFrame(fs, CFRangeMake(start, 0), path, nil)
            let visible = CTFrameGetVisibleStringRange(frame)
            if visible.length == 0 { break }
            ranges.append(CFRangeMake(start, visible.length))
            start += visible.length
        }
        return ranges
    }

    /// Zero-based page index containing character `loc` (clamped to the last page).
    private static func pageIndex(for loc: Int, in ranges: [CFRange]) -> Int {
        for (i, r) in ranges.enumerated() where loc >= r.location && loc < r.location + r.length {
            return i
        }
        return max(ranges.count - 1, 0)
    }

    /// Page number + note title in the bottom margin.
    private static func drawFooter(_ ctx: CGContext, page: Int, total: Int, title: String) {
        // Centered "Page X of Y".
        let num = NSAttributedString(string: "Page \(page) of \(total)", attributes: [
            .font: NSFont.systemFont(ofSize: 9), .foregroundColor: inkMuted,
        ])
        let numLine = CTLineCreateWithAttributedString(num)
        let numWidth = CTLineGetTypographicBounds(numLine, nil, nil, nil)
        ctx.textPosition = CGPoint(x: (pageSize.width - CGFloat(numWidth)) / 2, y: margin * 0.5)
        CTLineDraw(numLine, ctx)

        // Muted note title, left-aligned in the footer.
        let t = title.count > 60 ? String(title.prefix(59)) + "…" : title
        let name = NSAttributedString(string: t, attributes: [
            .font: NSFont.systemFont(ofSize: 8), .foregroundColor: inkMuted,
        ])
        ctx.textPosition = CGPoint(x: margin, y: margin * 0.5)
        CTLineDraw(CTLineCreateWithAttributedString(name), ctx)
    }

    // MARK: - Title block

    private static func buildHeader(title: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let tPara = NSMutableParagraphStyle()
        tPara.paragraphSpacing = 8
        tPara.lineSpacing = 1
        out.append(NSAttributedString(string: title + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 24, weight: .bold),
            .foregroundColor: inkHeading, .paragraphStyle: tPara,
        ]))
        appendRule(to: out, color: accent, thickness: 2, spacingBefore: 0, spacingAfter: 12)
        return out
    }

    // MARK: - Properties box

    /// A label/value list of the note's metadata — meeting type, date, the
    /// linked organisation / opportunity / project, attendees, and tags — so the
    /// PDF carries the same context the in-app viewer shows in its Properties box.
    private static func buildProperties(_ markdown: String,
                                        org: String?, opportunity: String?, project: String?) -> NSAttributedString {
        func fm(_ key: String) -> String? {
            FrontMatter.field(key, in: markdown)?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
                .nilIfEmpty
        }

        var rows: [(String, String)] = []
        if let t = fm("gw_meeting_type") { rows.append(("Meeting Type", prettyType(t))) }
        if let raw = fm("date"), let d = isoDate(raw) {
            rows.append(("Date", d.formatted(date: .abbreviated, time: .shortened)))
        }
        // Prefer the Catalog-resolved chain; fall back to the note's front-matter.
        if let v = org?.nilIfEmpty ?? fm("gw_org") { rows.append(("Organisation", v)) }
        if let v = opportunity?.nilIfEmpty ?? fm("gw_opportunity") { rows.append(("Opportunity", v)) }
        if let p = project?.nilIfEmpty { rows.append(("Project", p)) }
        for key in ["attendees", "people"] {
            let people = listField(key, in: markdown)
            if !people.isEmpty { rows.append(("Attendees", people.joined(separator: ", "))); break }
        }
        let boilerplate: Set<String> = ["meeting", "ghostwriter", "dictation"]
        let tags = FrontMatter.tags(in: markdown).filter { !boilerplate.contains($0.lowercased()) }
        if !tags.isEmpty { rows.append(("Tags", tags.joined(separator: ", "))) }

        guard !rows.isEmpty else { return NSAttributedString() }

        let out = NSMutableAttributedString()
        let labelWidth: CGFloat = 96
        for (label, value) in rows {
            let para = NSMutableParagraphStyle()
            para.headIndent = labelWidth
            para.paragraphSpacing = 4
            para.lineSpacing = 1.5
            para.tabStops = [NSTextTab(textAlignment: .left, location: labelWidth, options: [:])]
            let s = NSMutableAttributedString()
            s.append(NSAttributedString(string: label.uppercased() + "\t", attributes: [
                .font: NSFont.systemFont(ofSize: 8.5, weight: .semibold),
                .foregroundColor: inkMuted, .kern: 0.4, .paragraphStyle: para,
            ]))
            s.append(NSAttributedString(string: value + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 10.5),
                .foregroundColor: inkBody, .paragraphStyle: para,
            ]))
            out.append(s)
        }
        appendRule(to: out, color: inkRule, thickness: 0.75, spacingBefore: 11, spacingAfter: 13)
        return out
    }

    // MARK: - Content (body + trailing POC section)

    /// The document body followed by the POC section (when present). The POC
    /// heading is returned among `headings` so it appears in the Table of
    /// Contents with its own page number.
    private static func buildContent(body: String, poc: [POCItem])
        -> (NSAttributedString, [(level: Int, text: String, loc: Int)]) {
        let (bodyAttr, bodyHeadings) = buildBody(body)
        let out = NSMutableAttributedString()
        out.append(bodyAttr)
        var headings = bodyHeadings

        guard !poc.isEmpty else { return (out, headings) }

        // Register the POC heading for the TOC, rendered as a top-level (H1)
        // section so it matches body sections like "Agenda".
        let passed = poc.filter { $0.status.lowercased() == "passed" }.count
        headings.append((1, "POC Success Criteria", out.length))

        let hPara = NSMutableParagraphStyle()
        hPara.paragraphSpacing = 2
        hPara.paragraphSpacingBefore = 18
        out.append(NSAttributedString(string: "POC Success Criteria", attributes: [
            .font: h1Font, .foregroundColor: inkHeading, .paragraphStyle: hPara,
        ]))
        out.append(NSAttributedString(string: "   \(passed)/\(poc.count) passed\n", attributes: [
            .font: NSFont.systemFont(ofSize: 10.5), .foregroundColor: inkMuted, .paragraphStyle: hPara,
        ]))
        appendRule(to: out, color: inkRule, thickness: 0.75, spacingBefore: 3, spacingAfter: 10)
        for item in poc {
            let (glyph, color): (String, NSColor)
            switch item.status.lowercased() {
            case "passed": (glyph, color) = ("☑  ", NSColor(calibratedRed: 0.15, green: 0.5, blue: 0.2, alpha: 1))
            case "failed": (glyph, color) = ("☒  ", NSColor(calibratedRed: 0.65, green: 0.15, blue: 0.15, alpha: 1))
            default:       (glyph, color) = ("☐  ", inkMuted)
            }
            append(item.text, font: bodyFont, color: inkBody, spacingAfter: 3,
                   indent: 20, hanging: 20, marker: glyph, markerColor: color, to: out)
        }
        return (out, headings)
    }

    /// A comma/array front-matter field parsed into a list of names.
    private static func listField(_ key: String, in markdown: String) -> [String] {
        guard var v = FrontMatter.field(key, in: markdown) else { return [] }
        v = v.trimmingCharacters(in: .whitespaces)
        if v.hasPrefix("[") && v.hasSuffix("]") { v = String(v.dropFirst().dropLast()) }
        return v.split(separator: ",")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")) }
            .filter { !$0.isEmpty }
    }

    /// "customerCall" / "solution_demo" → "Customer Call" / "Solution Demo".
    private static func prettyType(_ id: String) -> String {
        var spaced = ""
        for ch in id.replacingOccurrences(of: "_", with: " ") {
            if ch.isUppercase, let last = spaced.last, last != " " { spaced.append(" ") }
            spaced.append(ch)
        }
        return spaced.split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    // MARK: - Table of contents

    /// Build the TOC and return, per entry, its character range within the TOC
    /// string — so the caller can lay clickable link rects over each row.
    private static func buildTOC(_ entries: [(level: Int, text: String)], pages: [Int])
        -> (attr: NSAttributedString, ranges: [CFRange]) {
        let out = NSMutableAttributedString()
        var ranges: [CFRange] = []
        let hPara = NSMutableParagraphStyle()
        hPara.paragraphSpacing = 8
        out.append(NSAttributedString(string: "Contents\n", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: inkHeading, .kern: 0.3, .paragraphStyle: hPara,
        ]))

        for (i, entry) in entries.enumerated() {
            let level = max(1, min(entry.level, 3))
            let indent = CGFloat(level - 1) * 16
            let para = NSMutableParagraphStyle()
            para.headIndent = indent
            para.firstLineHeadIndent = indent
            para.paragraphSpacing = 4
            para.lineSpacing = 1.5
            // Right tab stop parks the page number flush at the text edge.
            para.tabStops = [NSTextTab(textAlignment: .right, location: textWidth, options: [:])]

            let weight: NSFont.Weight = level == 1 ? .semibold : .regular
            let size: CGFloat = level == 1 ? 11 : 10.5
            let color = level == 1 ? inkHeading : inkBody
            let start = out.length
            out.append(NSAttributedString(string: "\(entry.text)\t\(pages[i])\n", attributes: [
                .font: NSFont.systemFont(ofSize: size, weight: weight),
                .foregroundColor: color, .paragraphStyle: para,
            ]))
            ranges.append(CFRangeMake(start, out.length - start))
        }
        appendRule(to: out, color: inkRule, thickness: 0.75, spacingBefore: 12, spacingAfter: 16)
        return (out, ranges)
    }

    // MARK: - Body

    /// Build the body attributed string, and collect the headings (with their
    /// character location inside that string) so the TOC can be laid out.
    private static func buildBody(_ body: String) -> (NSAttributedString, [(level: Int, text: String, loc: Int)]) {
        let out = NSMutableAttributedString()
        var headings: [(level: Int, text: String, loc: Int)] = []

        for rawLine in body.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                out.append(NSAttributedString(string: "\n", attributes: [.font: gap]))
                continue
            }
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                appendRule(to: out, color: inkRule, thickness: 0.75, spacingBefore: 6, spacingAfter: 8)
                continue
            }

            if trimmed.hasPrefix("### ") {
                headings.append((3, String(trimmed.dropFirst(4)), out.length))
                append(String(trimmed.dropFirst(4)), font: h3Font, color: inkHeading,
                       spacingBefore: 10, spacingAfter: 3, to: out)
            } else if trimmed.hasPrefix("## ") {
                headings.append((2, String(trimmed.dropFirst(3)), out.length))
                append(String(trimmed.dropFirst(3)), font: h2Font, color: inkHeading,
                       spacingBefore: 16, spacingAfter: 5, to: out)
            } else if trimmed.hasPrefix("# ") {
                headings.append((1, String(trimmed.dropFirst(2)), out.length))
                append(String(trimmed.dropFirst(2)), font: h1Font, color: inkHeading,
                       spacingBefore: 18, spacingAfter: 2, to: out)
                // A hairline under each top-level section for clear structure.
                appendRule(to: out, color: inkRule, thickness: 0.75, spacingBefore: 3, spacingAfter: 10)
            } else if let bullet = bulletContent(trimmed) {
                append(bullet.text, font: bodyFont, color: inkBody,
                       spacingAfter: 3, indent: 20, hanging: 20,
                       marker: bullet.marker, to: out)
            } else if trimmed.hasPrefix("> ") || trimmed == ">" {
                appendQuote(String(trimmed.dropFirst(trimmed.count > 1 ? 2 : 1)), to: out)
            } else {
                append(trimmed, font: bodyFont, color: inkBody, spacingAfter: 6, to: out)
            }
        }
        return (out, headings)
    }

    /// A block quote: italic, indented, muted.
    private static func appendQuote(_ text: String, to out: NSMutableAttributedString) {
        let para = NSMutableParagraphStyle()
        para.headIndent = 20
        para.firstLineHeadIndent = 20
        para.paragraphSpacing = 6
        para.lineSpacing = 2.5
        let italic = NSFontManager.shared.convert(bodyFont, toHaveTrait: .italicFontMask)
        out.append(NSAttributedString(string: text + "\n", attributes: [
            .font: italic, .foregroundColor: inkMuted, .paragraphStyle: para,
        ]))
    }

    /// A thin horizontal rule drawn with an underlined run of spaces.
    private static func appendRule(to out: NSMutableAttributedString, color: NSColor,
                                   thickness: CGFloat, spacingBefore: CGFloat, spacingAfter: CGFloat) {
        let para = NSMutableParagraphStyle()
        para.paragraphSpacingBefore = spacingBefore
        para.paragraphSpacing = spacingAfter
        out.append(NSAttributedString(string: "\u{00A0}\n", attributes: [
            .font: NSFont.systemFont(ofSize: thickness * 2),
            .strikethroughStyle: NSUnderlineStyle.single.rawValue,
            .strikethroughColor: color,
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
                               marker: String? = nil, markerColor: NSColor? = nil,
                               to out: NSMutableAttributedString) {
        let para = NSMutableParagraphStyle()
        para.paragraphSpacing = spacingAfter
        para.paragraphSpacingBefore = spacingBefore
        para.firstLineHeadIndent = indent - hanging
        para.headIndent = indent
        para.lineSpacing = 2.5

        if let marker {
            out.append(NSAttributedString(string: marker, attributes: [
                .font: font, .foregroundColor: markerColor ?? color, .paragraphStyle: para,
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

    // MARK: - Date

    private static func isoDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }

    // MARK: - Fonts

    private static let bodyFont = NSFont.systemFont(ofSize: 11)
    private static let h1Font   = NSFont.systemFont(ofSize: 22, weight: .bold)
    private static let h2Font   = NSFont.systemFont(ofSize: 15, weight: .semibold)
    private static let h3Font   = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
    private static let gap      = NSFont.systemFont(ofSize: 6)   // blank-line height
}

private extension String {
    /// nil when the string is empty after trimming — lets `if let` skip blanks.
    var nilIfEmpty: String? {
        trimmingCharacters(in: .whitespaces).isEmpty ? nil : self
    }
}
