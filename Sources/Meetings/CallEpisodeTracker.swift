import Foundation

// MARK: - Call Episode Tracker
//
// The "should we offer Meeting Mode now?" decision, kept free of CoreAudio and
// UI so it can be tested on its own. Fed once per poll with the call-like sources
// currently holding the microphone ("Zoom", "browser call (Google Chrome)", …).
//
// An *episode* lasts while any call source holds the mic. Within it, each
// distinct source is offered at most once — so declining a prompt, or recording
// the call, doesn't re-prompt every poll — but a **different** source that starts
// while another is still on the line (Zoom joining after a browser tab already
// holds the mic) is a new call and gets its own offer. Once the mic is quiet, the
// episode ends and everything is offered afresh next time.

struct CallEpisodeTracker {

    /// The browser's own call label ("browser call (Google Chrome)") — the same
    /// key the microphone scan uses, so a browser that has both an open meeting tab
    /// and the mic is one call, offered once.
    static func browserCallLabel(_ browser: String) -> String { "browser call (\(browser))" }

    /// Merge the microphone's call sources with an open meeting tab (if any).
    /// `tabLabel` is the tab's key, for matching the offered source back to it.
    static func offerSources(mic: [String], tab: (browser: String, service: String)?)
        -> (all: [String], tabLabel: String?) {
        guard let tab else { return (mic, nil) }
        let label = browserCallLabel(tab.browser)
        return (mic.contains(label) ? mic : mic + [label], label)
    }

    private var offered: Set<String> = []
    private(set) var current: [String] = []

    /// Feed one poll's call sources (native apps first). Returns the source to
    /// offer Meeting Mode for, or nil. While `suppressed` (we're already
    /// recording) nothing is offered, but the sources are remembered so the same
    /// call doesn't prompt the moment recording stops.
    mutating func observe(_ sources: [String], suppressed: Bool) -> String? {
        current = sources
        guard !sources.isEmpty else { offered.removeAll(); return nil }
        let fresh = sources.filter { !offered.contains($0) }
        offered.formUnion(sources)
        return suppressed ? nil : fresh.first
    }

    /// The user said "Not now", or stopped Meeting Mode mid-call: don't offer
    /// again for whatever is on the line right now.
    mutating func dismissCurrent() { offered.formUnion(current) }
}
