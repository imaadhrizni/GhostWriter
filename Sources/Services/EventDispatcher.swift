import Foundation

// MARK: - Event Dispatcher
//
// Fires user-configured integrations when a meeting is finalized, so power
// users can wire GhostWriter into their own tools (Notion, Slack, Zapier, a
// shell script) without waiting on a built-in integration.
//
// Two opt-in destinations, both off by default:
//   • a local script hook — runs a user-chosen executable with the event
//     payload as JSON on stdin (no network; easiest to trust), and
//   • an outgoing webhook — POSTs the same JSON to a user-configured https URL.
//
// Safety contract:
//   • Never runs in Local-only mode (that mode promises no outbound network,
//     and a webhook would break it; the script hook is suppressed too so the
//     mode is a single, predictable switch).
//   • The payload carries note metadata only — never raw audio.
//   • Free-text fields pass through the configured Redactor before leaving the
//     machine, so redaction settings apply here too.
//   • Endpoints are user-configured only — never sourced from note or web
//     content.

enum EventDispatcher {

    /// The JSON payload sent when a meeting finishes. Metadata only.
    struct MeetingFinishedPayload: Codable {
        var event: String = "meeting.finished"
        var title: String
        var file: String
        var date: String            // ISO8601
        var durationSeconds: Int
        var meetingType: String?
        var organisation: String?
        var project: String?
        var tags: [String]
    }

    /// Encode, then dispatch to whichever destinations are enabled. Best-effort
    /// and non-blocking — failures are logged, never surfaced mid-meeting.
    static func dispatch(_ payload: MeetingFinishedPayload) {
        let s = AppSettings.shared
        // Local-only mode is an absolute no-network promise.
        guard !s.localOnlyMode else { return }
        guard s.scriptHookEnabled || s.webhookEnabled else { return }

        let redacted = redact(payload)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let json = try? encoder.encode(redacted) else {
            Log.meeting.error("❌ Event payload encode failed")
            return
        }

        if s.scriptHookEnabled { runScript(path: s.scriptHookPath, json: json) }
        if s.webhookEnabled { postWebhook(urlString: s.webhookURL, json: json) }
    }

    // MARK: Redaction

    /// Apply the configured Redactor to the free-text fields. A no-op when
    /// redaction is disabled (Redactor short-circuits).
    private static func redact(_ p: MeetingFinishedPayload) -> MeetingFinishedPayload {
        var out = p
        out.title = Redactor.redact(p.title)
        out.organisation = p.organisation.map(Redactor.redact)
        out.project = p.project.map(Redactor.redact)
        out.tags = p.tags.map(Redactor.redact)
        return out
    }

    // MARK: Script hook

    private static func runScript(path: String, json: Data) {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let url = URL(fileURLWithPath: trimmed)
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            Log.meeting.error("❌ Script hook not executable: \(url.path, privacy: .public)")
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = url
            let stdin = Pipe()
            process.standardInput = stdin
            do {
                try process.run()
                stdin.fileHandleForWriting.write(json)
                try? stdin.fileHandleForWriting.close()
                process.waitUntilExit()
                Log.meeting.info("🔗 Script hook finished (exit \(process.terminationStatus))")
            } catch {
                Log.meeting.error("❌ Script hook failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: Webhook

    private static func postWebhook(urlString: String, json: Data) {
        let trimmed = urlString.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "https" else {
            Log.meeting.error("❌ Webhook URL missing or not https — skipped")
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = json
        request.timeoutInterval = 15
        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error {
                Log.meeting.error("❌ Webhook POST failed: \(error.localizedDescription, privacy: .public)")
            } else if let code = (response as? HTTPURLResponse)?.statusCode {
                Log.meeting.info("🔗 Webhook POST → \(code)")
            }
        }.resume()
    }
}
