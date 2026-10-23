import Foundation

// MARK: - Web Meeting
//
// Recognises a browser address that is an actual conferencing meeting — a Zoom
// web-client or join page, a Google Meet room, a Teams meeting, a Webex room —
// so Meeting Mode can be offered when you *join*, before the microphone is open
// (Zoom's web client often doesn't touch the mic until you unmute or choose
// "Join Audio", so a mic-only detector stays silent).
//
// Deliberately strict: only addresses that name a specific meeting match. A
// service's home, pricing, sign-in, or landing pages must not trigger a prompt.
// Pure and local — no I/O; the caller supplies the URL.

enum WebMeeting {

    /// The service ("Zoom", "Google Meet", "Microsoft Teams", "Webex") whose
    /// meeting `url` points at, or nil if it isn't a meeting address.
    static func service(for url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        let path = url.path.lowercased()
        let fragment = (url.fragment ?? "").lowercased()
        let query = (url.query ?? "").lowercased()

        func isHost(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
        func matches(_ pattern: String, _ text: String) -> Bool { text.range(of: pattern, options: .regularExpression) != nil }

        if isHost("zoom.us") || isHost("zoom.com") || isHost("zoomgov.com") {
            // The *web client* only: /wc/<id>/join, /wc/<id>/start, /wc/join/<id>. The /j/<id> page
            // is the landing page everyone sees before the desktop app launches — prompting there
            // would nag desktop-app users (the app then raises its own prompt when it takes the mic).
            if matches(#"^/wc/(join/|start/)?\d{8,12}"#, path) { return "Zoom" }
            return nil
        }
        if host == "meet.google.com" {
            // A meeting code like abc-defg-hij (or a /lookup/ short link). Not /landing, /new, or the home page.
            if matches(#"^/[a-z]{3}-[a-z]{4}-[a-z]{3}(/|$)"#, path) || path.hasPrefix("/lookup/") { return "Google Meet" }
            return nil
        }
        if host == "teams.live.com" {
            return path.hasPrefix("/meet/") ? "Microsoft Teams" : nil
        }
        if isHost("teams.microsoft.com") {
            let all = path + " " + fragment + " " + query
            if all.contains("meetup-join") || all.contains("pre-join") || all.contains("meetingjoin=true") { return "Microsoft Teams" }
            return nil
        }
        if isHost("webex.com") {
            if path.hasPrefix("/meet/") || path.contains("/wbxmjs/") || path.contains("/webappng/") { return "Webex" }
            return nil
        }
        return nil
    }
}

// MARK: - Tab Call Hold
//
// Remembers that a meeting tab was seen, so one meeting isn't re-offered every
// few seconds and a brief look at another tab doesn't forget it. Fed one reading
// per poll. A meeting seen is held until either the browser has shown some *other*
// tab for a few minutes (you've left it), or it hasn't been seen at all for a long
// while (the browser isn't frontmost — we can't tell, so we're patient).

struct TabCallHold {
    enum Reading {
        case unread                                       // browser not frontmost / not scriptable / throttled
        case other                                        // frontmost browser, active tab isn't a meeting
        case meeting(browser: String, service: String)
    }

    static let leftTabAfter: TimeInterval = 180           // seen elsewhere this long → left the meeting
    static let unseenAfter: TimeInterval = 600            // not seen at all this long → let go

    private var held: (browser: String, service: String, lastMeeting: Date, firstOther: Date?)?

    /// The meeting tab currently considered open, if any.
    mutating func observe(_ reading: Reading, now: Date) -> (browser: String, service: String)? {
        switch reading {
        case .meeting(let browser, let service):
            held = (browser, service, now, nil)
        case .other:
            if var h = held {
                h.firstOther = h.firstOther ?? now
                held = now.timeIntervalSince(h.firstOther!) >= Self.leftTabAfter ? nil : h
            }
        case .unread:
            if let h = held, now.timeIntervalSince(h.lastMeeting) > Self.unseenAfter { held = nil }
        }
        return held.map { ($0.browser, $0.service) }
    }
}
