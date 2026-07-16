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
// Fires `onMeetingDetected` once per call; re-arms when the capture stops.
final class MeetingDetector {

    /// Called on the main thread with a human-readable source ("Zoom",
    /// "browser call (Google Chrome)").
    var onMeetingDetected: ((String) -> Void)?

    /// Called on the main thread when a tracked call releases the microphone —
    /// the cue to offer stopping Meeting Mode instead of recording silence.
    var onCallEnded: (() -> Void)?

    /// While true (we are recording ourselves), *start* prompts are
    /// suppressed. Call-end tracking keeps running so a meeting being
    /// transcribed still gets its "call ended" signal.
    var suppressed = false

    private var timer: Timer?
    private var armed = true             // one prompt per mic-capture episode
    private var snoozedThisCall = false  // user said no / stopped — skip the rest of this call
    private var activeSource: String?    // the call currently being tracked
    private var quietPolls = 0           // consecutive polls with no call mic — debounce for end

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
    /// no more prompts until the current call ends (mic released). The next
    /// call prompts fresh.
    func snooze() {
        snoozedThisCall = true
    }

    // MARK: - Polling

    private func poll() {
        guard AppSettings.shared.meetingAutoDetect else { return }

        guard let source = Self.micCapturingCallSource() else {
            // Nobody call-like holds the mic. A configurable number of quiet
            // polls in a row counts as the call ending — a single blip doesn't.
            if activeSource != nil {
                quietPolls += 1
                guard quietPolls >= AppSettings.shared.meetingEndQuietPolls else { return }
                Log.meeting.info("👂 Call ended (\(self.activeSource ?? "?") released the mic)")
                activeSource = nil
                quietPolls = 0
                onCallEnded?()
            }
            // Fully re-arm so the next call prompts again.
            armed = true
            snoozedThisCall = false
            return
        }

        quietPolls = 0
        activeSource = source

        guard !suppressed, armed, !snoozedThisCall else { return }
        armed = false
        Log.meeting.info("👂 Detected \(source) using the microphone")
        onMeetingDetected?(source)
    }

    // MARK: - CoreAudio process inspection

    /// The call-like source currently capturing the microphone, if any.
    private static func micCapturingCallSource() -> String? {
        let ownBundle = Bundle.main.bundleIdentifier?.lowercased() ?? ""
        for bundleID in bundleIDsCapturingInput() {
            guard bundleID != ownBundle else { continue }
            if let app = meetingApps.first(where: { bundleID.hasPrefix($0.prefix) }) {
                return app.name
            }
            if let browser = browsers.first(where: { bundleID.hasPrefix($0.prefix) }) {
                return "browser call (\(browser.name))"
            }
        }
        return nil
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
