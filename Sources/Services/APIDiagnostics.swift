import Foundation

// MARK: - API Diagnostics
//
// The single place a failed Groq call is turned into diagnosable evidence:
// one structured line in the persistent file log AND a failure entry (status,
// reason, latency) in the per-call `APIUsageLog`. Chat, streaming chat, and
// transcription all report through here so the format never drifts.
//
// Privacy: records the endpoint, feature label, model, HTTP status, timings,
// rate-limit headers, and the server's error text — never the request body
// (prompt / transcript / audio) and never the API key.

enum APIDiagnostics {

    /// Response headers worth keeping when a call fails — the ones that explain
    /// a rate limit or let Groq support trace a request.
    private static let interestingHeaders = [
        "retry-after",
        "x-ratelimit-limit-requests", "x-ratelimit-remaining-requests", "x-ratelimit-reset-requests",
        "x-ratelimit-limit-tokens", "x-ratelimit-remaining-tokens", "x-ratelimit-reset-tokens",
        "x-request-id",
    ]

    /// Milliseconds elapsed since `started`.
    static func latencyMs(since started: Date) -> Int {
        Int(Date().timeIntervalSince(started) * 1000)
    }

    /// Log + record one failed call. Pass `response` for an HTTP error (with the
    /// server's `body`), or `error` for a transport failure (timeout, offline…).
    static func failure(kind: APIUsageLog.Kind, source: String, model: String, endpoint: String,
                        started: Date, response: HTTPURLResponse? = nil,
                        body: String = "", error: Error? = nil) {
        let ms = latencyMs(since: started)
        let status = response?.statusCode
        let reason = error.map(describe) ?? collapse(body, limit: 500)

        var parts = ["✖ \(endpoint) \"\(source)\" model=\(model)"]
        parts.append(status.map { "HTTP \($0)" } ?? "transport error")
        parts.append("\(ms)ms")
        parts.append(contentsOf: headerSummary(response))
        if !reason.isEmpty { parts.append("— \(reason)") }
        Log.api.error(parts.joined(separator: " "))

        switch kind {
        case .chat:
            APIUsageLog.shared.recordChat(source: source, model: model, inputTokens: 0, outputTokens: 0,
                                          ok: false, status: status, failure: reason, latencyMs: ms)
        case .transcription:
            APIUsageLog.shared.recordTranscription(source: source, model: model, audioSeconds: 0,
                                                   ok: false, status: status, failure: reason, latencyMs: ms)
        }
    }

    /// Debug-level trace of a successful call (written only with Verbose logging).
    static func success(endpoint: String, source: String, model: String, started: Date, detail: String) {
        Log.api.debug("✔ \(endpoint) \"\(source)\" model=\(model) \(latencyMs(since: started))ms \(detail)")
    }

    // MARK: Formatting

    /// `retry-after=12 remaining-tokens=0 …` for whichever interesting headers exist.
    private static func headerSummary(_ response: HTTPURLResponse?) -> [String] {
        guard let response else { return [] }
        return interestingHeaders.compactMap { name in
            guard let value = response.value(forHTTPHeaderField: name), !value.isEmpty else { return nil }
            return "\(name.replacingOccurrences(of: "x-ratelimit-", with: ""))=\(value)"
        }
    }

    /// A transport error with its code, so a timeout (-1001) is distinguishable
    /// from "offline" (-1009) at a glance.
    private static func describe(_ error: Error) -> String {
        if let url = error as? URLError { return "\(url.localizedDescription) (URLError \(url.code.rawValue))" }
        return error.localizedDescription
    }

    /// Single-line, length-capped server text.
    private static func collapse(_ text: String, limit: Int) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }
}
