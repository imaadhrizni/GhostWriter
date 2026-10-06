import Foundation

// MARK: - AI Gate
//
// A single global chokepoint every cloud AI request passes through. Two jobs:
//
//   1. Concurrency cap — bound how many requests are in flight at once, per
//      lane, so parallel fan-out (meeting-end refinement, follow-up packets,
//      an in-flight straggler tick) can't stack into a rate-limit storm. Chat
//      and transcription have separate lanes/limits since they're separate
//      Groq endpoints with independent quotas — summary fan-out must never
//      starve live transcription.
//
//   2. Adaptive rate-limit backoff — when a request comes back rate-limited
//      (HTTP 429 / quota), pause the whole gate for a growing interval so the
//      next requests wait instead of hammering. This is the ONE place that
//      reacts to 429; model-availability faults are ModelResolver's job.
//
//   3. Retry + token-budget pacing — a 429 is retried after the wait the
//      server asked for (`retry-after`), up to `maxRetries`, so a rate limit
//      delays a feature instead of silently dropping it. Waits longer than
//      `maxWait` (e.g. a daily quota) are not retried. Separately, every chat
//      response teaches the gate each model's tokens-per-minute allowance
//      (Groq's `x-ratelimit-*-tokens` headers); later calls reserve their
//      estimated tokens against it and queue for the next window rather than
//      launching into a guaranteed 429. Meeting-end enrichment sends the whole
//      transcript several times at once — on a small allowance (the free tier
//      is 8,000 tokens/minute/model) that burst can only succeed if paced.
//
// Every caller wraps its network call in `AIGate.shared.run(lane) { … }`; the
// two API clients (TextPolisher, GroqService) do this once, so all features
// inherit the guard without changes.
actor AIGate {
    static let shared = AIGate()

    enum Lane: Hashable { case chat, transcription }

    /// A read-only view of the gate for the Settings diagnostics readout.
    struct Snapshot: Sendable {
        var chatActive: Int, chatCap: Int, chatWaiting: Int
        var transcriptionActive: Int, transcriptionCap: Int, transcriptionWaiting: Int
        /// Seconds remaining on the shared rate-limit cooldown (0 = not paused).
        var pausedFor: TimeInterval
    }

    /// Max requests in flight per lane. Deliberately conservative so bursts stay
    /// within typical Groq tier limits; not user-configurable (a wrong value
    /// just trades latency for 429s — the gate already adapts to real limits).
    private let caps: [Lane: Int] = [.chat: 3, .transcription: 2]

    private var active: [Lane: Int] = [:]
    private var waiters: [Lane: [CheckedContinuation<Void, Never>]] = [:]

    /// While set (and in the future), new requests wait until this instant —
    /// the shared cooldown after a rate-limit response.
    private var pausedUntil: Date?
    private var backoff: TimeInterval = 0
    private static let firstBackoff: TimeInterval = 4
    private static let maxBackoff: TimeInterval = 32

    /// A model's tokens-per-minute allowance, modelled as the token bucket Groq
    /// uses: `remaining` tokens as of `asOf`, refilling continuously at
    /// `limit / 60` per second, capped at `limit`. `remaining` is last taken from
    /// the server's headers, less what this gate has since reserved.
    private struct Budget {
        var limit: Int
        var remaining: Double
        var asOf: Date

        var refillPerSecond: Double { Double(limit) / 60 }

        func available(at now: Date) -> Double {
            min(Double(limit), remaining + refillPerSecond * now.timeIntervalSince(asOf))
        }
    }
    private var budgets: [String: Budget] = [:]

    /// Each model's per-minute allowance, remembered across launches so the very
    /// first burst after startup can already be paced and routed (without it the
    /// gate knows nothing until a model's first response). The bucket is assumed
    /// full at launch — right unless the app was restarted mid-burst.
    private static let learnedLimitsKey = "ai.learnedModelLimits"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let saved = defaults.dictionary(forKey: Self.learnedLimitsKey) as? [String: Int] {
            for (model, limit) in saved where limit > 0 {
                budgets[model] = Budget(limit: limit, remaining: Double(limit), asOf: Date())
            }
        }
    }

    /// Tokens promised to calls that have *picked* a model but not started yet.
    /// Without this, calls choosing at the same instant all see the same "free"
    /// model and stampede onto it. Entries expire so an abandoned pick can't
    /// block a model.
    private var pending: [String: [(at: Date, tokens: Int)]] = [:]
    private static let pendingTTL: TimeInterval = 30

    /// Models the server told us to stay off until a given time (the `retry-after`
    /// of their last rate-limit). Lets the failover router steer around a
    /// saturated or quota-exhausted model without probing it again.
    private var unavailableUntil: [String: Date] = [:]

    /// Retries per call after a rate limit, and the longest single wait we'll
    /// sit through (a longer `retry-after` is a quota, not a burst).
    private static let maxRetries = 2
    private static let maxWait: TimeInterval = 75

    /// Run `op` under the lane's concurrency cap, the shared rate-limit cooldown,
    /// and — when `model` is given — that model's token budget (`estimatedTokens`
    /// is reserved against it). A rate-limited result is retried after the
    /// server's `retry-after`; any other error, or a wait longer than `maxWait`,
    /// is rethrown. The lane slot is released while waiting, so a stalled call
    /// never blocks other work.
    func run<T: Sendable>(_ lane: Lane, model: String? = nil, estimatedTokens: Int = 0,
                          retries: Int? = nil,
                          _ op: @Sendable () async throws -> T) async throws -> T {
        let maxRetries = retries ?? Self.maxRetries
        var attempt = 0
        while true {
            await waitOutCooldown()
            if let model {
                if attempt == 0 { consumePending(model) }
                try await awaitBudget(model, estimate: estimatedTokens)
            }
            await acquire(lane)
            do {
                let result = try await op()
                release(lane)
                backoff = 0                     // success clears the escalation
                return result
            } catch {
                release(lane)
                guard (error as? GroqError)?.isRateLimited == true else { throw error }
                let hinted: TimeInterval?
                if case .rateLimited(let after, _)? = error as? GroqError { hinted = after } else { hinted = nil }
                if let model, let hinted { unavailableUntil[model] = Date().addingTimeInterval(hinted) }
                // When the server named the wait, honour exactly that (per-model
                // pacing keeps siblings in line); only an unexplained limit
                // escalates the shared cooldown.
                if hinted == nil { armBackoff() }
                guard attempt < maxRetries, case .rateLimited? = error as? GroqError else { throw error }
                let delay = (hinted ?? Self.firstBackoff * pow(2, Double(attempt))) + 0.5
                guard delay <= Self.maxWait else { throw error }
                attempt += 1
                Log.api.info("↻ Rate limited — retrying in \(Int(delay.rounded(.up)))s (retry \(attempt)/\(maxRetries))")
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    /// Learn a model's allowance from a response's rate-limit headers. Called by
    /// the chat client on every response (success or failure).
    func noteBudget(model: String, response: HTTPURLResponse) {
        guard let limit = Int(response.value(forHTTPHeaderField: "x-ratelimit-limit-tokens") ?? ""),
              let remaining = Int(response.value(forHTTPHeaderField: "x-ratelimit-remaining-tokens") ?? "")
        else { return }
        noteBudget(model: model, limit: limit, remaining: remaining)
    }

    /// Set a model's allowance directly — from headers, or from the exact
    /// `Limit N, Used U` in a 429 body (more trustworthy: for some models, e.g.
    /// Qwen, the headers describe a different limit than the one being enforced).
    func noteBudget(model: String, limit: Int, remaining: Int) {
        guard limit > 0 else { return }
        let changed = budgets[model]?.limit != limit
        budgets[model] = Budget(limit: limit, remaining: Double(max(0, remaining)), asOf: Date())
        if changed {
            var saved = (defaults.dictionary(forKey: Self.learnedLimitsKey) as? [String: Int]) ?? [:]
            saved[model] = limit
            defaults.set(saved, forKey: Self.learnedLimitsKey)
        }
    }

    /// How long until `model` could take `estimate` more tokens: the server's
    /// cooldown for it, or the time its token bucket needs to cover the deficit —
    /// counting what other callers have already promised themselves from it. A
    /// model we know nothing about counts as ready.
    private func expectedWait(_ model: String, estimate: Int, now: Date) -> TimeInterval {
        var seconds = max(0, unavailableUntil[model]?.timeIntervalSince(now) ?? 0)
        if let budget = budgets[model], estimate <= budget.limit {
            let promised = Double(pendingTokens(model, now: now))
            seconds = max(seconds, Self.secondsUntil(available: budget.available(at: now) - promised,
                                                     need: estimate, limit: budget.limit))
        }
        return seconds
    }

    /// The best model in `chain` for `estimate` tokens right now, and how long it
    /// would have to wait: the first (in preference order) that can start within
    /// `tolerance` seconds, else the one that frees up soonest. Does not reserve.
    func plan(_ chain: [String], estimate: Int, tolerance: TimeInterval = 15) -> (model: String, wait: TimeInterval) {
        let now = Date()
        let waits = chain.map { (model: $0, wait: expectedWait($0, estimate: estimate, now: now)) }
        if let ready = waits.first(where: { $0.wait <= tolerance }) { return ready }
        return waits.min(by: { $0.wait < $1.wait }) ?? (chain.first ?? "", 0)
    }

    /// Promise `estimate` tokens of `model` to a call that is about to start, so
    /// callers choosing at the same moment see it as that much busier.
    func reserve(_ model: String, estimate: Int) {
        pending[model, default: []].append((Date(), estimate))
    }

    /// `plan` + `reserve`: pick the best model and claim the capacity.
    func pickModel(_ chain: [String], estimate: Int, tolerance: TimeInterval = 15) -> String {
        let choice = plan(chain, estimate: estimate, tolerance: tolerance)
        reserve(choice.model, estimate: estimate)
        return choice.model
    }

    private func pendingTokens(_ model: String, now: Date) -> Int {
        let live = (pending[model] ?? []).filter { now.timeIntervalSince($0.at) < Self.pendingTTL }
        pending[model] = live
        return live.reduce(0) { $0 + $1.tokens }
    }

    /// A call that picked `model` has started: its promise is now real usage
    /// (tracked by the bucket), so drop the oldest reservation.
    private func consumePending(_ model: String) {
        if var list = pending[model], !list.isEmpty {
            list.removeFirst()
            pending[model] = list
        }
    }

    /// Seconds until a bucket holding `available` tokens (of `limit` per minute)
    /// can cover `need` — i.e. just the deficit at the refill rate, not a full
    /// window reset. 0 when it already can.
    static func secondsUntil(available: Double, need: Int, limit: Int) -> TimeInterval {
        let deficit = Double(need) - available
        return deficit > 0 ? deficit / (Double(limit) / 60) : 0
    }

    /// Current in-flight / waiting counts and cooldown — for diagnostics.
    func snapshot() -> Snapshot {
        Snapshot(
            chatActive: active[.chat] ?? 0, chatCap: caps[.chat] ?? 0,
            chatWaiting: waiters[.chat]?.count ?? 0,
            transcriptionActive: active[.transcription] ?? 0, transcriptionCap: caps[.transcription] ?? 0,
            transcriptionWaiting: waiters[.transcription]?.count ?? 0,
            pausedFor: pausedUntil.map { max(0, $0.timeIntervalSinceNow) } ?? 0)
    }

    // MARK: Concurrency

    private func acquire(_ lane: Lane) async {
        let cap = caps[lane] ?? 3
        if (active[lane] ?? 0) < cap {
            active[lane, default: 0] += 1
            return
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            waiters[lane, default: []].append(c)
        }
        active[lane, default: 0] += 1
    }

    private func release(_ lane: Lane) {
        active[lane, default: 1] -= 1
        if var queue = waiters[lane], !queue.isEmpty {
            let next = queue.removeFirst()
            waiters[lane] = queue
            next.resume()
        }
    }

    // MARK: Rate-limit cooldown

    private func waitOutCooldown() async {
        guard let until = pausedUntil else { return }
        let delay = until.timeIntervalSinceNow
        guard delay > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
    }

    // MARK: Token budget

    /// Wait until `model`'s bucket can cover `estimate` tokens, then reserve
    /// them. A model we've never heard limits from passes straight through (the
    /// first 429 teaches us). A request larger than the whole allowance can never
    /// fit, so it's let through to fail with the server's own message.
    private func awaitBudget(_ model: String, estimate: Int) async throws {
        guard estimate > 0 else { return }
        while true {
            guard var budget = budgets[model] else { return }
            let now = Date()
            let available = budget.available(at: now)
            if estimate > budget.limit || available >= Double(estimate) {
                budget.remaining = max(0, available - Double(estimate))
                budget.asOf = now
                budgets[model] = budget
                return
            }
            let needed = Self.secondsUntil(available: available, need: estimate, limit: budget.limit)
            let wait = min(needed, Self.maxWait) + 0.25
            Log.api.info("⏳ \(model) token budget low (\(Int(available))/\(budget.limit), need ~\(estimate)) — waiting \(Int(wait.rounded(.up)))s")
            try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        }
    }

    private func armBackoff() {
        backoff = backoff == 0 ? Self.firstBackoff : min(backoff * 2, Self.maxBackoff)
        pausedUntil = Date().addingTimeInterval(backoff)
        Log.api.warning("⏸ Rate limited — pausing all AI calls for \(Int(backoff))s")
    }
}
