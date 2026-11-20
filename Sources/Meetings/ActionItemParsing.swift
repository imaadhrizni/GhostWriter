import Foundation

// MARK: - Action Item Parsing
//
// The pure text layer behind action items: finding the bullets under a note's
// "## Action Items" heading, reading the "@owner" and "(due: …)" annotations the
// summary writes, parsing a due date, and recognising the "none" placeholders the
// model writes when a section is empty. No file I/O and no UI, so it is testable
// on its own; `NotesLibrary.ActionItem` and `NotesLibrary.openQuestions` build on it.
//
// One due-date parser for the whole app: the Digest, the Catalog dashboard, the
// Reminders export and the Action Items screen all read `dueDate(from:relativeTo:)`,
// so "overdue" can't mean different things in different places. The model writes
// dates in the words people use — "tomorrow", "Monday", "end of next week", "30 Dec"
// — so those are understood, resolved against the *meeting's* date (a "tomorrow"
// from three weeks ago is long overdue). Placeholders and anything ambiguous
// ("next sync", "ASAP"-less vagueness, a transcript timestamp) yield no date.

enum ActionItemParsing {

    /// A bullet under the heading, before any file context is attached.
    struct Raw: Equatable {
        /// Everything after the checkbox, verbatim — so a toggle can rewrite the
        /// line without losing the owner/due annotations.
        let text: String
        let done: Bool
        /// The exact trimmed source line, used to find it again for a toggle.
        let rawLine: String
    }

    /// Bullets under the "## Action Items" heading of a note's text. Handles `-`/`*`
    /// bullets, `[ ]`/`[x]` checkboxes (including a repeated "[x] [x]"), and skips
    /// "none" placeholders so an empty section yields no items.
    static func items(in content: String) -> [Raw] {
        var out: [Raw] = []
        var inSection = false
        for rawLine in content.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.lowercased().hasPrefix("## action items") { inSection = true; continue }
            guard inSection else { continue }
            if line.hasPrefix("#") { inSection = false; continue }
            guard line.hasPrefix("-") || line.hasPrefix("*") else { continue }

            var text = line.dropFirst().trimmingCharacters(in: .whitespaces)
            var done = false
            while text.hasPrefix("[ ]") || text.lowercased().hasPrefix("[x]") {
                if text.lowercased().hasPrefix("[x]") { done = true }
                text = text.dropFirst(3).trimmingCharacters(in: .whitespaces)
            }
            if !text.isEmpty, !isNonePlaceholder(String(text)) {
                out.append(Raw(text: String(text), done: done, rawLine: line))
            }
        }
        return out
    }

    /// Bullets under a note's questions section(s): the canonical `## Open Questions`
    /// and the legacy `## Unanswered Questions` (older notes, the structured-extraction
    /// block). `done` reflects a `- [x]` checkbox; plain `-`/`*` bullets read as open.
    /// Items from both headings are merged and de-duplicated case-insensitively, and
    /// "none" placeholders — the model writes `- _None_` under an empty section —
    /// are skipped: that is the absence of questions, not a question called "None".
    static func questions(in text: String) -> [Raw] {
        var out: [Raw] = []
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
            guard !body.isEmpty, !isNonePlaceholder(body), seen.insert(body.lowercased()).inserted else { continue }
            out.append(Raw(text: body, done: done, rawLine: line))
        }
        return out
    }

    // MARK: Annotations

    // Owner is only recognised in the trailing "— @owner" position the summary
    // emits, so an @mention or email inside the action text isn't taken for the
    // assignee.
    private static let ownerRegex = try! NSRegularExpression(pattern: "[—–-]\\s*@([\\w][\\w.'-]*)")
    private static let dueRegex = try! NSRegularExpression(pattern: "\\(due:\\s*([^)]*)\\)", options: [.caseInsensitive])

    private static func firstGroup(_ regex: NSRegularExpression, in text: String) -> String? {
        guard let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    static func owner(in text: String) -> String? { firstGroup(ownerRegex, in: text) }

    /// The due annotation as written ("2026-11-10", "Friday", …), or nil when there
    /// isn't a real one: "none" / "not specified" placeholders, and a bare transcript
    /// timestamp ("12:34:12" — the model sometimes copies one into the field), are
    /// not due dates and are not shown as one.
    static func due(in text: String) -> String? {
        guard let raw = firstGroup(dueRegex, in: text)?.trimmingCharacters(in: .whitespaces),
              !isDuePlaceholder(raw) else { return nil }
        return raw
    }

    /// "none", "not specified", "TBD", "[date not specified]", or a bare clock time.
    static func isDuePlaceholder(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: CharacterSet(charactersIn: "_*`~ ()[]—–-.")).lowercased()
        if isNonePlaceholder(t) { return true }
        if ["not specified", "unspecified", "not set", "tbd", "tba", "no date", "no due date", "no deadline",
            "date not specified", "none specified", "not stated"].contains(t) { return true }
        return t.range(of: #"^\d{1,2}:\d{2}(:\d{2})?$"#, options: .regularExpression) != nil
    }

    /// The action alone — the "@owner" / "(due: …)" chips and any trailing "—"
    /// separator removed — for a clean row and a Reminders title.
    static func displayText(of text: String) -> String {
        var s = text
        s = dueRegex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
        s = ownerRegex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
        s = s.trimmingCharacters(in: .whitespaces)
        while s.hasSuffix("—") || s.hasSuffix("-") || s.hasSuffix(",") {
            s = String(s.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        return s.isEmpty ? text : s
    }

    /// A due annotation as a calendar day (start of day), or nil when it can't be pinned
    /// to one. `reference` is the day the meeting happened — relative phrases ("tomorrow",
    /// "Monday", "next week") are resolved against it; it defaults to today.
    ///
    /// Understood: ISO dates (also with typographic hyphens, e.g. "2026‑11‑07"); today /
    /// tonight / EOD / ASAP; tomorrow; weekday names ("Monday", "next Friday"); this week /
    /// end of week; next week / end of next week; "in 3 days", "2 weeks", "12 months";
    /// "30 Dec", "Nov 10", "10 November 2026". Everything else — "next sync", "before the
    /// sign-off", placeholders — is nil: better no date than a wrong one.
    static func dueDate(from due: String?, relativeTo reference: Date? = nil) -> Date? {
        guard let due, !isDuePlaceholder(due) else { return nil }
        let cal = calendar
        let ref = cal.startOfDay(for: reference ?? Date())
        // One hyphen for every dash lookalike; lower-case; brackets and stray punctuation out.
        let t = due.lowercased()
            .replacingOccurrences(of: "[\u{2010}\u{2011}\u{2012}\u{2013}\u{2014}\u{2212}]", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]()_* ."))

        func day(_ y: Int, _ m: Int, _ d: Int) -> Date? {
            guard let date = cal.date(from: DateComponents(year: y, month: m, day: d)),
                  cal.dateComponents([.year, .month, .day], from: date) == DateComponents(year: y, month: m, day: d)
            else { return nil }
            return date
        }
        func add(_ comp: Calendar.Component, _ n: Int, to d: Date = ref) -> Date? { cal.date(byAdding: comp, value: n, to: d) }
        func match(_ pattern: String) -> [String]? {
            guard let re = try? NSRegularExpression(pattern: pattern),
                  let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) else { return nil }
            return (0..<m.numberOfRanges).map { i in Range(m.range(at: i), in: t).map { String(t[$0]) } ?? "" }
        }
        func has(_ words: String...) -> Bool { words.contains { t.contains($0) } }

        // 1. ISO date.
        if let m = match(#"^(\d{4})-(\d{1,2})-(\d{1,2})"#), let y = Int(m[1]), let mo = Int(m[2]), let d = Int(m[3]) {
            return day(y, mo, d)
        }
        // 2. Relative to the meeting day.
        if has("tomorrow") { return add(.day, 1) }
        if has("today", "tonight", "eod", "end of day", "asap", "immediately", "right away", "next hour") { return ref }
        let weekdays = ["sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4, "thursday": 5, "friday": 6, "saturday": 7,
                        "sun": 1, "mon": 2, "tue": 3, "tues": 3, "wed": 4, "thu": 5, "thur": 5, "thurs": 5, "fri": 6, "sat": 7]
        if let m = match(#"\b(?:(next|this|coming)\s+)?(sunday|monday|tuesday|wednesday|thursday|friday|saturday|sun|mon|tues?|wed|thur?s?|fri|sat)\b"#),
           let target = weekdays[m[2]] {
            let from = cal.component(.weekday, from: ref)
            var delta = (target - from + 7) % 7
            if delta == 0 { delta = 7 }                       // "Monday", said on a Monday → next Monday
            var result = add(.day, delta)
            if m[1] == "next", let r = result, cal.isDate(r, equalTo: ref, toGranularity: .weekOfYear) { result = add(.day, 7, to: r) }
            return result
        }
        if has("end of next week", "next week", "following week") { return fridayOfWeek(offset: 1, from: ref, cal) }
        if has("this week", "end of week", "end of the week", "eow", "by the end of the week") { return fridayOfWeek(offset: 0, from: ref, cal) }
        if let m = match(#"\b(?:in\s+)?(\d{1,3}|an?|one|two|three|four|five|six|seven|eight|nine|ten)\s+(day|week|month)s?\b"#) {
            let words = ["a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10]
            if let n = Int(m[1]) ?? words[m[1]] {
                switch m[2] { case "day": return add(.day, n); case "week": return add(.day, 7 * n); default: return add(.month, n) }
            }
        }
        // 3. A calendar date without a weekday: "30 dec", "nov 10", "10 november 2026", "nov 10, 2026".
        let months = ["jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6, "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12]
        let name = #"(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*"#
        var dd: Int?, mm: Int?, yy: Int?
        if let m = match(#"\b(\d{1,2})(?:st|nd|rd|th)?\s+"# + name + #"\b(?:,?\s+(\d{4}))?"#) { dd = Int(m[1]); mm = months[m[2]]; yy = Int(m[3]) }
        else if let m = match(#"\b"# + name + #"\s+(\d{1,2})(?:st|nd|rd|th)?\b(?:,?\s+(\d{4}))?"#) { mm = months[m[1]]; dd = Int(m[2]); yy = Int(m[3]) }
        if let dd, let mm {
            let refYear = cal.component(.year, from: ref)
            guard var d = day(yy ?? refYear, mm, dd) else { return nil }
            // No year stated: pick the occurrence that makes sense — a date well behind the
            // meeting day (60+ days) is next year's.
            if yy == nil, let gap = cal.dateComponents([.day], from: d, to: ref).day, gap > 60, let next = day(refYear + 1, mm, dd) { d = next }
            return d
        }
        return nil
    }

    /// The Friday of the calendar week `offset` weeks from `ref`'s (weeks start Monday);
    /// when `ref` is already past that Friday, the next one.
    private static func fridayOfWeek(offset: Int, from ref: Date, _ cal: Calendar) -> Date? {
        let weekday = cal.component(.weekday, from: ref)                 // 1 = Sunday … 7 = Saturday
        let toFriday = (6 - weekday + 7) % 7                             // days until Friday (0 on Friday)
        // On Saturday/Sunday "this week" has ended → the coming Friday.
        guard let thisFriday = cal.date(byAdding: .day, value: toFriday, to: ref) else { return nil }
        return cal.date(byAdding: .day, value: 7 * offset, to: thisFriday)
    }

    private static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.firstWeekday = 2
        return c
    }()

    // MARK: Placeholders

    /// True when a bullet is a "no items" placeholder rather than real content —
    /// stripped of markdown emphasis and punctuation it reads as none / n/a / "no
    /// open questions" etc. The model writes `- _None_` under empty sections.
    static func isNonePlaceholder(_ s: String) -> Bool {
        let stripped = s
            .trimmingCharacters(in: CharacterSet(charactersIn: "_*`~ ()—–-."))
            .lowercased()
        return ["", "none", "n/a", "na", "nil", "nothing", "no action items", "no items",
                "no open questions", "no unanswered questions", "no questions"].contains(stripped)
    }
}
