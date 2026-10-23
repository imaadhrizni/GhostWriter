import AppKit

// MARK: - Browser URL Reader
//
// Reads the active tab's URL from the frontmost browser via AppleScript so
// dictation styling can distinguish, say, Gmail from GitHub inside a browser.
// Requires the Automation (Apple Events) permission — the first read triggers
// a one-time consent prompt. Firefox isn't scriptable this way (returns nil).
// Everything degrades gracefully to nil, which callers treat as "just a browser".

enum BrowserURL {

    /// AppleScript to fetch the active tab URL, keyed by browser bundle ID.
    /// Chromium-family browsers share one form; Safari differs.
    private static func script(forBundleID id: String) -> String? {
        switch id.lowercased() {
        case "com.apple.safari":
            return "tell application \"Safari\" to return URL of front document"
        case "com.google.chrome":       return chromium("Google Chrome")
        case "com.google.chrome.canary":return chromium("Google Chrome Canary")
        case "com.brave.browser":       return chromium("Brave Browser")
        case "com.microsoft.edgemac":   return chromium("Microsoft Edge")
        case "company.thebrowser.browser": return chromium("Arc")
        case "com.operasoftware.opera": return chromium("Opera")
        case "com.vivaldi.vivaldi":     return chromium("Vivaldi")
        default:
            return nil   // Firefox and others: not scriptable
        }
    }

    private static func chromium(_ app: String) -> String {
        "tell application \"\(app)\" to return URL of active tab of front window"
    }

    /// Whether `bundleID` is a browser we can read the active tab from.
    static func isReadable(_ bundleID: String) -> Bool { script(forBundleID: bundleID) != nil }

    /// The frontmost browser's active-tab URL. `denied` is true when macOS refused
    /// the Automation (Apple Events) permission, so a caller can say so once
    /// instead of failing silently. Must run on the main thread.
    @MainActor
    static func read(forBundleID bundleID: String) -> (url: URL?, denied: Bool) {
        guard let source = script(forBundleID: bundleID),
              let apple = NSAppleScript(source: source) else { return (nil, false) }
        var error: NSDictionary?
        let output = apple.executeAndReturnError(&error)
        if let error {
            // -1743: "not authorized to send Apple events" (permission not granted).
            let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
            return (nil, code == -1743)
        }
        return (output.stringValue.flatMap { URL(string: $0) }, false)
    }

    /// The host (e.g. "mail.google.com") of the frontmost browser's active tab,
    /// or nil if unavailable / unsupported / permission denied.
    /// Must run on the main thread (NSAppleScript requirement).
    @MainActor
    static func host(forBundleID bundleID: String) -> String? {
        guard let host = read(forBundleID: bundleID).url?.host else { return nil }
        // Normalize: drop a leading "www." so rules can match either way.
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
