import Foundation

// MARK: - Date Display
//
// Formats the `yyyy-MM-dd` day keys (parsed from note filenames) into the
// user-configurable display format used across the menu and Catalog.
// Filenames themselves stay in the fixed, parseable timestamp format — this
// only affects what's shown.

enum DateDisplay {

    /// Fixed, locale-independent formatter for the `yyyy-MM-dd` day key used in
    /// note filenames/folders. Configured once and only read → safe to share.
    static let posixDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Shared ISO-8601 formatter for writing front-matter `date:` stamps —
    /// one instance instead of the ad-hoc `ISO8601DateFormatter()` that was
    /// scattered across the note writer.
    static let iso8601 = ISO8601DateFormatter()

    /// Parse an ISO-8601 `date:` string, tolerating fractional seconds. Used by
    /// the PDF export and note viewer (previously duplicated `isoDate(_:)`
    /// helpers). Uses its own formatters so no shared mutable state is toggled.
    static func parseISO(_ s: String) -> Date? {
        if let d = isoPlain.date(from: s) { return d }
        return isoFractional.date(from: s)
    }
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Fixed formatter for the full `yyyy-MM-dd_HH-mm-ss` filename timestamp.
    static let posixTimestamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f
    }()

    /// Build a locale-independent (POSIX) formatter for an arbitrary fixed
    /// pattern — the one place that stamps stable, non-display date strings
    /// (month keys, folder names). Callers that reuse a fixed pattern should
    /// prefer the cached `posixDay`/`posixTimestamp` above.
    static func posixFormatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f
    }

    /// Parses the fixed `yyyy-MM-dd` day key. POSIX so it's locale-independent.
    private static var parser: DateFormatter { posixDay }

    /// Reused output formatter; reconfigured when the chosen format changes.
    /// UI-only, main-thread use.
    private static let out = DateFormatter()

    /// Format a `yyyy-MM-dd` day key for display (e.g. "03 Jul 2026").
    /// Falls back to the raw key if it can't be parsed or the format is empty.
    static func day(_ ymd: String) -> String {
        let format = AppSettings.shared.uiDateFormat
        guard !format.isEmpty, let date = parser.date(from: ymd) else { return ymd }
        if out.dateFormat != format {
            out.locale = .current      // localized month/day names
            out.dateFormat = format
        }
        return out.string(from: date)
    }

    /// Preview of today's date in a given format (for the Settings picker).
    static func preview(_ format: String) -> String {
        guard !format.isEmpty else { return "" }
        let f = DateFormatter()
        f.locale = .current
        f.dateFormat = format
        return f.string(from: Date())
    }
}
