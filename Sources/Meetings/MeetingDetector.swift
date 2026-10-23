import AppKit
import CoreAudio

// MARK: - Meeting Detector
//
// Notices when a call is likely starting by asking CoreAudio *which process*
// is capturing the microphone (kAudioHardwarePropertyProcessObjectList +
// kAudioProcessPropertyIsRunningInput — same macOS 14.2+ family as the
// process taps used for system-audio capture).
//
// Two kinds of matches:
//   • a native conferencing app (Zoom, Teams, …) capturing the mic
//   • a web browser capturing the mic — that's a browser call
//     (Google Meet, Teams web, Discord web, …)
//
// Fires `onMeetingDetected` once per distinct call source (see
// `CallEpisodeTracker`); re-arms when the capture stops. Whenever the set of
// processes holding the mic changes it writes one line to the debug log, so a
// call that wasn't noticed can be traced to the process that held the mic.
final class MeetingDetector {

    /// Called on the main thread with a human-readable source ("Zoom",
    /// "browser call (Google Chrome)") and, when the call was recognised from an
    /// open meeting tab, the service it is ("Zoom", "Google Meet", …).
    var onMeetingDetected: ((String, String?) -> Void)?

    /// Called on the main thread when a tracked call releases the microphone —
    /// the cue to offer stopping Meeting Mode instead of recording silence.
    var onCallEnded: (() -> Void)?

    /// While true (we are recording ourselves), *start* prompts are
    /// suppressed. Call-end tracking keeps running so a meeting being
    /// transcribed still gets its "call ended" signal.
    var suppressed = false

    private var timer: Timer?
    private var episode = CallEpisodeTracker()   // which call sources have already been offered
    private var activeSource: String?    // the call currently being tracked
    private var quietPolls = 0           // consecutive polls with no call mic — debounce for end
    private var lastHolders = ""         // last logged set of mic-holding processes (log on change only)
    private var tabHold = TabCallHold()  // a web-meeting tab seen in the frontmost browser
    private var lastTabRead = Date.distantPast
    private var tabDenied = Set<String>() // browsers whose Automation permission was refused (logged once each)
    private var lastTabLog = ""

    /// Bundle-ID prefixes of native conferencing apps.
    private static let meetingApps: [(prefix: String, name: String)] = [
        ("us.zoom",             "Zoom"),
        ("com.microsoft.teams", "Microsoft Teams"),
        ("com.cisco.webex",     "Webex"),
        ("com.webex",           "Webex"),
        ("com.hnc.discord",     "Discord"),
        ("com.skype.skype",     "Skype"),
        ("com.ringcentral",     "RingCentral"),
        ("com.gotomeeting",     "GoTo Meeting"),
        ("com.slack",           "Slack"),   // huddles
    ]

    /// Bundle-ID prefixes of browsers — a browser holding the mic open means
    /// a web call (Google Meet has no native app).
    private static let browsers: [(prefix: String, name: String)] = [
        ("com.google.chrome",          "Google Chrome"),
        ("com.apple.safari",           "Safari"),
        ("org.mozilla.firefox",        "Firefox"),
        ("com.microsoft.edgemac",      "Microsoft Edge"),
        ("company.thebrowser.browser", "Arc"),
        ("com.brave.browser",          "Brave"),
        ("com.vivaldi.vivaldi",        "Vivaldi"),
        ("com.operasoftware",          "Opera"),
    ]

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: AppSettings.shared.meetingDetectInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        Log.meeting.info("👂 Meeting detection active")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Call when the user declines a prompt or stops Meeting Mode mid-call:
    /// no more prompts for what's on the line now until it ends (mic released).
    /// A different app starting a call still gets offered.
    func snooze() {
        episode.dismissCurrent()
    }

    // MARK: - Polling

    private func poll() {
        guard AppSettings.shared.meetingAutoDetect else { return }

        let scan = Self.scanMic()
        logHolders(scan.holders)
        let tab = readTab()

        // Call END is judged by the microphone alone: a tab can stay open long
        // after the call, so it must never keep a call "alive" or end one.
        if scan.sources.isEmpty {
            // Nobody call-like holds the mic. A configurable number of quiet
            // polls in a row counts as the call ending — a single blip doesn't.
            if activeSource != nil {
                quietPolls += 1
                if quietPolls >= AppSettings.shared.meetingEndQuietPolls {
                    Log.meeting.info("👂 Call ended (\(self.activeSource ?? "?") released the mic)")
                    activeSource = nil
                    quietPolls = 0
                    onCallEnded?()
                }
            }
        } else {
            quietPolls = 0
            activeSource = scan.sources[0]
        }

        // OFFERING Meeting Mode considers the mic *and* an open meeting tab. The
        // tab's key is the browser's own call label, so a browser that has both an
        // open meeting page and the mic is one call, offered once.
        let (offerSources, tabLabel) = CallEpisodeTracker.offerSources(mic: scan.sources, tab: tab)

        if let source = episode.observe(offerSources, suppressed: suppressed) {
            let service = (source == tabLabel) ? tab?.service : nil
            let basis = scan.sources.contains(source) ? "using the microphone" : "open in the browser (microphone not in use yet)"
            Log.meeting.info("👂 Detected \(service.map { "\($0) — " } ?? "")\(source) \(basis)")
            onMeetingDetected?(source, service)
        }
    }

    // MARK: - Browser tab

    /// The meeting open in the frontmost browser's active tab, held across brief
    /// glances at other tabs (`TabCallHold`). Reads only while a scriptable browser
    /// is frontmost, at most every few seconds, and logs a recognised meeting's
    /// service and browser — never the address.
    private func readTab() -> (browser: String, service: String)? {
        guard AppSettings.shared.meetingTabDetection else { return nil }
        let now = Date()

        guard let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier?.lowercased(),
              BrowserURL.isReadable(id),
              let browser = Self.browsers.first(where: { id.hasPrefix($0.prefix) })?.name,
              now.timeIntervalSince(lastTabRead) >= 4 else {
            return tabHold.observe(.unread, now: now)
        }
        lastTabRead = now

        let result = MainActor.assumeIsolated { BrowserURL.read(forBundleID: id) }
        if result.denied {
            if tabDenied.insert(id).inserted {
                Log.meeting.warning("🌐 Can't read \(browser)'s active tab — macOS Automation permission was refused. Allow GhostWriter under System Settings → Privacy & Security → Automation to detect web meetings.")
            }
            return tabHold.observe(.unread, now: now)
        }
        let reading: TabCallHold.Reading = result.url.flatMap(WebMeeting.service(for:))
            .map { .meeting(browser: browser, service: $0) } ?? .other
        let held = tabHold.observe(reading, now: now)

        let logKey = held.map { "\($0.service)|\($0.browser)" } ?? ""
        if logKey != lastTabLog {
            lastTabLog = logKey
            if let held { Log.meeting.info("🌐 \(held.service) meeting tab open in \(held.browser)") }
            else { Log.meeting.info("🌐 Meeting tab closed or left") }
        }
        return held
    }

    /// One log line each time the set of mic-holding processes changes — the
    /// record that explains a call which wasn't noticed ("Chrome helper held the
    /// mic but matched nothing", "no process held it at all").
    private func logHolders(_ holders: [String]) {
        let key = holders.sorted().joined(separator: "; ")
        guard key != lastHolders else { return }
        let hadAny = !lastHolders.isEmpty
        lastHolders = key
        if holders.isEmpty { if hadAny { Log.meeting.info("👂 Microphone released by every process") } }
        else { Log.meeting.info("👂 Mic in use by: \(key)") }
    }

    // MARK: - CoreAudio process inspection

    /// Every process holding the mic (`holders`, as "bundle id → what we made of
    /// it") and the distinct call-like sources among them (`sources`, native
    /// conferencing apps first, then browsers).
    private static func scanMic() -> (sources: [String], holders: [String]) {
        let ownBundle = Bundle.main.bundleIdentifier?.lowercased() ?? ""
        var native: [String] = [], web: [String] = [], holders: [String] = []
        for bundleID in bundleIDsCapturingInput() where bundleID != ownBundle {
            if let app = meetingApps.first(where: { bundleID.hasPrefix($0.prefix) }) {
                holders.append("\(bundleID) → \(app.name)")
                if !native.contains(app.name) { native.append(app.name) }
            } else if let browser = browsers.first(where: { bundleID.hasPrefix($0.prefix) }) {
                let label = CallEpisodeTracker.browserCallLabel(browser.name)
                holders.append("\(bundleID) → \(label)")
                if !web.contains(label) { web.append(label) }
            } else {
                holders.append("\(bundleID) → not a recognized call app")
            }
        }
        return (native + web, holders)
    }

    /// Bundle IDs of all processes currently running audio *input*.
    private static func bundleIDsCapturingInput() -> [String] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
            size > 0 else { return [] }

        var processes = [AudioObjectID](
            repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &processes) == noErr
        else { return [] }

        var result: [String] = []
        for process in processes {
            var running: UInt32 = 0
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            var runningAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningInput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(
                process, &runningAddress, 0, nil, &runningSize, &running) == noErr,
                running != 0 else { continue }

            var bundleRef: Unmanaged<CFString>?
            var bundleSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var bundleAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyBundleID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            let status = withUnsafeMutablePointer(to: &bundleRef) { ptr in
                AudioObjectGetPropertyData(process, &bundleAddress, 0, nil, &bundleSize, ptr)
            }
            guard status == noErr, let bundleID = bundleRef?.takeRetainedValue() else { continue }

            let id = (bundleID as String).lowercased()
            if !id.isEmpty { result.append(id) }
        }
        return result
    }
}
