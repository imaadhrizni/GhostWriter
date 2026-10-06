import Foundation

// MARK: - Groq Error
//
// Errors from the Groq API. HTTP failures are built through `GroqError.http`
// so a 429 becomes `.rateLimited` carrying the server's `retry-after` — the
// signal `AIGate` uses to wait and retry instead of failing the feature.

enum GroqError: LocalizedError {
    case missingAPIKey
    case invalidResponse
    case apiError(statusCode: Int, message: String)
    /// HTTP 429. `retryAfter` is how long the server says to wait (nil if it
    /// didn't say); `message` is Groq's explanation (which limit, how much used).
    case rateLimited(retryAfter: TimeInterval?, message: String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Groq API key not set. Add one via the menu bar → Set API Key…"
        case .invalidResponse:
            return "Invalid response from Groq API."
        case .apiError(let code, let message):
            return "Groq API error (\(code)): \(message)"
        case .rateLimited(let retryAfter, let message):
            let wait = retryAfter.map { " Try again in about \(Int($0.rounded(.up)))s." } ?? ""
            return "Groq rate limit reached.\(wait) \(message)"
        }
    }

    /// A rate-limit / quota response — the signal AIGate backs off and retries
    /// on. Distinct from a model-availability fault, which ModelResolver handles.
    var isRateLimited: Bool {
        switch self {
        case .rateLimited: return true
        case .apiError(let code, let message):
            let m = message.lowercased()
            return code == 429 || m.contains("rate_limit") || m.contains("quota")
        default: return false
        }
    }

    // MARK: Building from an HTTP response

    /// The error for a non-200 response: `.rateLimited` for 429, else `.apiError`.
    static func http(_ response: HTTPURLResponse, body: String) -> GroqError {
        guard response.statusCode == 429 else {
            return .apiError(statusCode: response.statusCode, message: String(body.prefix(200)))
        }
        let message = serverMessage(in: body) ?? String(body.prefix(200))
        return .rateLimited(retryAfter: retryAfter(response, body: body), message: message)
    }

    /// Seconds to wait: the `retry-after` header, else Groq's "try again in 32.1s"
    /// text in the body.
    static func retryAfter(_ response: HTTPURLResponse, body: String) -> TimeInterval? {
        if let header = response.value(forHTTPHeaderField: "retry-after"), let s = Double(header) { return s }
        guard let match = body.range(of: #"try again in (\d+(?:\.\d+)?)s"#, options: .regularExpression) else { return nil }
        return Double(body[match].filter { "0123456789.".contains($0) })
    }

    /// The `Limit N, Used U` of a *per-minute token* limit named in a 429 body
    /// (TPM or ITPM) — exact, unlike the response headers, which for some models
    /// describe a different limit than the one enforced. nil for other limits
    /// (requests per minute, tokens per **day**), which aren't a bucket to pace by.
    static func tokenUsage(in body: String) -> (limit: Int, used: Int)? {
        guard body.contains("tokens per minute"),
              let m = body.range(of: #"Limit (\d+), Used (\d+)"#, options: .regularExpression) else { return nil }
        let nums = body[m].split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        return nums.count == 2 ? (nums[0], nums[1]) : nil
    }

    /// Groq's `error.message` from a JSON error body, if present.
    private static func serverMessage(in body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any],
              let message = error["message"] as? String else { return nil }
        // Drop the upsell sentence — it's noise in a diagnostic.
        return message.components(separatedBy: " Need more tokens?").first
    }
}
