import Foundation

// MARK: - Redactor
//
// Optional, opt-in scrubbing of sensitive tokens from transcribed text before
// it is typed, written to a notes file, or sent to the polishing/summary LLM.
// Applied at the single choke point (transcribeWithFallback) so it covers
// dictation, quick notes, and meetings uniformly. Off by default.

enum Redactor {

    /// Redact the configured categories from `text`. Returns the text unchanged
    /// when redaction is disabled.
    static func redact(_ text: String) -> String {
        let s = AppSettings.shared
        guard s.redactionEnabled else { return text }

        var out = text
        // Emails first (the "@" makes them unambiguous), then long digit runs
        // (cards / account numbers) before phone numbers, since the phone
        // pattern is broader and would otherwise swallow them.
        if s.redactEmails {
            out = replace(out,
                          pattern: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#,
                          with: "[redacted email]")
        }
        if s.redactNumbers {
            out = replace(out,
                          pattern: #"(?<!\d)(?:\d[ -]?){13,19}(?!\d)"#,
                          with: "[redacted number]")
        }
        if s.redactPhones {
            out = replace(out,
                          pattern: #"(?<!\d)\+?\d[\d\s().-]{7,}\d(?!\d)"#,
                          with: "[redacted phone]")
        }
        return out
    }

    private static func replace(_ text: String, pattern: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: replacement)
    }
}
