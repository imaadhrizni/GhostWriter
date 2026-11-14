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

// MARK: - Call Boundary Tracker
//
// "Has a *different* call started while we're still recording the first?" — the
// miss behind two back-to-back meetings landing in one note. While Meeting Mode
// runs the start prompt is (rightly) suppressed, and the end-of-call debounce
// can't tell a few seconds of silence between two calls from a mute, so without
// this the second call is silently recorded into the first one's note.
//
// Pure and clock-injected like `CallEpisodeTracker`. Three independent signals,
// each chosen to stay quiet on an ordinary mid-call mute or reconnect:
//
//   A. The meeting tab changed identity (Meet room abc-… → xyz-…, or Meet →
//      Teams) and stayed changed for two reads. Needs a tab known at the start.
//   B. A meeting tab appeared that we hadn't seen at the start, *and then* the mic
//      was released and re-taken — the join of a second call after leaving the
//      first. (Either alone is common within one call.)
//   C. A call ended while we kept recording (the user chose "Keep Recording"),
//      and a call source took the mic again after at least `reacquireGap`.

struct CallBoundaryTracker {

    /// What a poll can see of the meeting tab.
    struct Tab: Equatable {
        var key: String        // identity — see `WebMeeting.meetingKey`
        var service: String    // "Google Meet", "Microsoft Teams", …
        var label: String      // the browser's call label, as offered/recorded
    }

    struct NewCall: Equatable {
        var source: String
        var service: String?
    }

    /// Quiet this long after "call ended" before a returning mic counts as a new call.
    static let reacquireGap: TimeInterval = 120

    private var started = false
    private var baseline: String?
    private var candidate: (tab: Tab, reads: Int)?
    private var pendingTab: Tab?
    private var micQuietSeen = false
    private var endedAt: Date?

    /// Forget everything — recording started, or stopped.
    mutating func reset() { self = CallBoundaryTracker() }

    /// The detector reported the tracked call over while we are still recording.
    mutating func noteCallEnded(at now: Date) { endedAt = now }

    /// Feed one poll made *while recording a meeting*. Returns the new call, if one
    /// just began.
    mutating func observe(now: Date, tab: Tab?, micSources: [String]) -> NewCall? {
        let micHeld = !micSources.isEmpty
        if !micHeld { micQuietSeen = true }

        if !started {
            started = true
            baseline = tab?.key
        }

        // C — the mic came back long after a call ended that we kept recording through.
        if let ended = endedAt, micHeld {
            endedAt = nil
            if now.timeIntervalSince(ended) >= Self.reacquireGap {
                return fire(tab: tab, source: tab?.label ?? micSources[0])
            }
        }

        guard let tab else { candidate = nil; return nil }

        if tab.key == baseline { candidate = nil; pendingTab = nil; return nil }

        if baseline != nil {
            // A — a different meeting tab, seen twice running.
            let reads = (candidate?.tab.key == tab.key ? candidate!.reads : 0) + 1
            candidate = (tab, reads)
            if reads >= 2 { return fire(tab: tab, source: tab.label) }
        } else {
            // B — a tab we didn't start with; wait for the mic to cycle.
            if pendingTab?.key != tab.key { pendingTab = tab; micQuietSeen = !micHeld }
            if micHeld, micQuietSeen { return fire(tab: tab, source: tab.label) }
        }
        return nil
    }

    private mutating func fire(tab: Tab?, source: String) -> NewCall {
        baseline = tab?.key ?? baseline
        candidate = nil; pendingTab = nil; micQuietSeen = false; endedAt = nil
        return NewCall(source: source, service: tab?.service)
    }
}
