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

    /// Fixed formatter for the full `yyyy-MM-dd_HH-mm-ss` filename timestamp.
    static let posixTimestamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f
    }()

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
