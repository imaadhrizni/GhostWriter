import Foundation

// MARK: - Model Resolver
//
// Groq adds and decommissions models on its own schedule, so a model id saved
// in Settings can silently stop existing — and, because ~10 call sites read the
// model straight from Settings, that surfaces as scattered "model does not
// exist" failures across dictation, live brief, meeting-end, packets, imports.
//
// `ModelResolver` is the single place that maps *what the user picked* to *a
// model that actually exists right now*:
//   • keeps a cached copy of Groq's live catalog (GET /v1/models),
//   • resolves a configured id to itself when available, else to the best
//     available fallback for that role,
//   • classifies an API error as a model-availability fault vs. a rate/quota
//     problem (the latter is emphatically NOT its job — see AIGate).
//
// The configured setting is never overwritten: an unavailable choice is routed
// around transparently (and badged ⚠ in Settings), so if Groq re-adds it, it
// comes back. Catalog cached in Application Support (rebuildable). Thread-safe:
// `resolve`/`isAvailable` are synchronous and callable from any actor (the
// model accessors are synchronous computed properties).
final class ModelResolver {
    static let shared = ModelResolver()

    /// What a given call needs from a model — not a specific id.
    enum Role {
        case transcription, summary, lightweight, reasoning

        /// Whether a catalog id is a plausible model for this role — used both to
        /// populate the Settings preset menu and to pick a live last-resort when
        /// none of the ordered fallbacks exist. Transcription wants Whisper;
        /// chat roles want anything that isn't speech/moderation-only.
        func matches(_ id: String) -> Bool {
            let m = id.lowercased()
            let isSpeech = m.contains("whisper") || m.contains("tts") || m.contains("playai")
            let isGuard = m.contains("guard")
            switch self {
            case .transcription: return m.contains("whisper")
            default:             return !isSpeech && !isGuard
            }
        }
    }

    /// A model-availability fault (the model is gone / unknown). Distinct from
    /// rate-limit/quota, which this deliberately does not treat as a fault.
    enum Fault { case decommissioned }

    /// Posted (once per configured id) when a configured model is unavailable
    /// and gets routed to a fallback — so the app can surface a toast.
    /// userInfo: `["from": <configured>, "to": <resolved>]`.
    static let didAutoSwitch = Notification.Name("ModelResolverDidAutoSwitch")

    /// Ordered fallbacks per role. Only a tie-breaker: the live catalog is the
    /// source of truth, and resolution always intersects with it. Kept short
    /// (these age); prefer non-reasoning chat models for summary/lightweight
    /// since the pipeline expects plain Markdown in `content`.
    static let preferences: [Role: [String]] = [
        .transcription: ["whisper-large-v3", "whisper-large-v3-turbo"],
        .summary:       ["llama-3.3-70b-versatile", "llama-3.1-70b-versatile"],
        .lightweight:   ["llama-3.3-70b-versatile", "openai/gpt-oss-20b"],
        .reasoning:     ["openai/gpt-oss-120b", "openai/gpt-oss-20b"],
    ]

    private struct Cache: Codable { var ids: [String]; var fetchedAt: Date }

    private let queue = DispatchQueue(label: "com.ghostwriter.modelresolver")
    private var cache: Cache?
    private let url: URL
    private let ttl: TimeInterval = 12 * 3600
    /// OpenAI-compatible API base URL (Groq by default; user-configurable).
    private var baseURL: String { AppSettings.shared.apiBaseURL }
    private var refreshing = false
    private var warned = Set<String>()   // configured ids already toasted

    private var apiKey: String { KeychainService.groqAPIKey() ?? "" }

    private init() {
        url = AppPaths.support().appendingPathComponent("ModelCatalog.json")
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(Cache.self, from: data) {
            cache = decoded
        }
    }

    // MARK: Resolution (synchronous, thread-safe)

    /// Whether the live catalog contains this id. `false` if the catalog hasn't
    /// been fetched yet (callers treat "unknown" as "don't badge as missing").
    func isAvailable(_ id: String) -> Bool {
        queue.sync { cache?.ids.contains(id) ?? false }
    }

    /// Whether we have a catalog at all (so the UI can avoid ⚠-badging every
    /// model just because we haven't fetched yet).
    var hasCatalog: Bool { queue.sync { !(cache?.ids.isEmpty ?? true) } }

    /// When the catalog was last fetched, and how many models it lists — for
    /// the Settings "Model availability" readout.
    var lastFetched: Date? { queue.sync { cache?.fetchedAt } }
    var catalogCount: Int { queue.sync { cache?.ids.count ?? 0 } }

    /// A short, human-friendly blurb for a model id, to help pick from the
    /// dropdown. Groq's catalog API returns only ids (no descriptions), so this
    /// curates the families we know and otherwise derives a hint (family + size)
    /// from the id, so even an unfamiliar model gets a useful one-liner.
    static func describe(_ id: String) -> String {
        let m = id.lowercased()
        // Exact, curated blurbs for the models we ship as presets / defaults.
        let known: [String: String] = [
            "whisper-large-v3":           "Highest accuracy — best for noisy/multilingual audio",
            "whisper-large-v3-turbo":     "Faster, still multilingual — good default",
            "distil-whisper-large-v3-en": "Fastest & cheapest, English-only",
            "llama-3.3-70b-versatile":    "Best all-round quality — recommended",
            "llama-3.1-70b-versatile":    "Older 70B — use only if 3.3 is gone",
            "llama-3.1-8b-instant":       "Cheapest & fastest, lower quality — being retired",
            "openai/gpt-oss-120b":        "Deepest reasoning for hard tasks — slowest",
            "openai/gpt-oss-20b":         "Strong reasoning, lighter — faster than 120B",
            "groq/compound":              "Agentic — LLM with built-in web search & tools",
            "groq/compound-mini":         "Lighter agentic model with built-in tools",
        ]
        if let d = known[m] { return d }

        // Derive a hint for anything else: family + parameter size when present.
        let family: String? =
            m.contains("whisper")           ? "Speech-to-text" :
            m.contains("guard")             ? "Safety / moderation model" :
            (m.contains("tts") || m.contains("playai")) ? "Text-to-speech" :
            m.contains("compound")          ? "Agentic system with built-in tools" :
            m.contains("gpt-oss")           ? "OpenAI open-weight reasoning" :
            m.contains("llama")             ? "Meta Llama chat model" :
            m.contains("qwen")              ? "Alibaba Qwen chat model" :
            m.contains("gemma")             ? "Google Gemma chat model" :
            m.contains("kimi") || m.contains("moonshot") ? "Moonshot Kimi chat model" :
            m.contains("deepseek")          ? "DeepSeek reasoning model" : nil

        // Pull the first "<n>b" token as a parameter-size badge (e.g. "70b").
        let size = m.split(whereSeparator: { !"0123456789b".contains($0) })
            .first(where: { $0.hasSuffix("b") && $0.dropLast().allSatisfy(\.isNumber) })
            .map { "~\($0.dropLast())B params" }

        switch (family, size) {
        case let (f?, s?): return "\(f) · \(s)"
        case let (f?, nil): return f
        case let (nil, s?): return s
        default:            return ""
        }
    }

    /// Live catalog ids relevant to a role, sorted — so the Settings preset menu
    /// can offer *only models that actually exist* (a pick that isn't in the
    /// catalog would just get routed around, making the dropdown feel inert).
    /// Empty when the catalog hasn't been fetched yet; callers fall back to their
    /// static preset list then.
    func catalogModels(for role: Role) -> [String] {
        let ids = queue.sync { cache?.ids ?? [] }
        return ids.filter { role.matches($0) }.sorted()
    }

    /// If `configured` isn't in the catalog and resolves to something else, post
    /// `didAutoSwitch` once per configured id so the app can toast the swap.
    func announceIfSubstituted(_ role: Role, configured: String?) {
        let want = configured?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !want.isEmpty, hasCatalog, !isAvailable(want) else { return }
        let resolved = resolve(role, configured: want)
        guard resolved != want else { return }
        let post: Bool = queue.sync { warned.insert(want).inserted }
        guard post else { return }
        NotificationCenter.default.post(name: Self.didAutoSwitch, object: nil,
                                        userInfo: ["from": want, "to": resolved])
    }

    /// Map a configured id to one that exists: the configured id if available,
    /// else the first available fallback for the role, else the configured id
    /// unchanged (offline / catalog-unknown — let the request try and, if it
    /// faults, the retry path refreshes and re-resolves).
    func resolve(_ role: Role, configured: String?) -> String {
        queue.sync {
            let ids = cache?.ids ?? []
            let want = configured?.trimmingCharacters(in: .whitespaces) ?? ""
            if ids.isEmpty { return want.isEmpty ? (Self.preferences[role]?.first ?? "") : want }
            if !want.isEmpty, ids.contains(want) { return want }
            for pref in Self.preferences[role] ?? [] where ids.contains(pref) { return pref }
            // The configured id is gone and none of our ordered fallbacks exist
            // in the live catalog either (they age out too). Rather than hand back
            // a dead id that's guaranteed to 404, land on any live model that fits
            // the role — a working request beats a broken one.
            if let live = ids.filter({ role.matches($0) }).sorted().first { return live }
            return want.isEmpty ? (Self.preferences[role]?.first ?? "") : want
        }
    }

    // MARK: Error classification

    /// Classify an API error. Returns `.decommissioned` for a model-availability
    /// problem (triggers refresh + re-resolve); `nil` for anything else,
    /// including rate-limit/quota — which is AIGate's concern, never a reason to
    /// switch models.
    func classify(_ error: Error) -> Fault? {
        guard case let GroqError.apiError(status, message) = error else { return nil }
        let m = message.lowercased()
        if status == 429 || m.contains("rate_limit") || m.contains("quota") { return nil }
        if status == 404 || m.contains("model_not_found") || m.contains("does not exist")
            || m.contains("decommission") || m.contains("deprecat") {
            return .decommissioned
        }
        return nil
    }

    // MARK: Catalog refresh

    /// Fetch and cache Groq's live model list. Skips when the cache is fresh
    /// (unless `force`), and coalesces concurrent callers so a burst of faults
    /// triggers a single fetch.
    func refresh(force: Bool = false) async {
        let stale: Bool = queue.sync {
            guard let c = cache else { return true }
            return Date().timeIntervalSince(c.fetchedAt) > ttl
        }
        guard force || stale else { return }
        let start: Bool = queue.sync {
            if refreshing { return false }
            refreshing = true
            return true
        }
        guard start else { return }
        defer { queue.sync { refreshing = false } }

        guard !apiKey.isEmpty else { return }
        var request = URLRequest(url: URL(string: "\(baseURL)/models")!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let decoded = try? JSONDecoder().decode(ModelList.self, from: data) else { return }
        let ids = decoded.data.map(\.id)
        guard !ids.isEmpty else { return }
        queue.sync {
            cache = Cache(ids: ids, fetchedAt: Date())
            if let out = try? JSONEncoder().encode(cache) { try? out.write(to: url, options: .atomic) }
        }
        // Now that we know what exists, toast any configured model we're routing
        // around (once each).
        let s = AppSettings.shared
        announceIfSubstituted(.transcription, configured: s.transcriptionModel)
        announceIfSubstituted(.summary, configured: s.polishingModel)
        announceIfSubstituted(.lightweight, configured: s.fastModel)
    }

    private struct ModelList: Codable {
        let data: [Entry]
        struct Entry: Codable { let id: String }
    }
}
