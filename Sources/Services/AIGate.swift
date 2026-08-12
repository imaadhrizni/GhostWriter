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

    /// Run `op` under the lane's concurrency cap and the shared rate-limit
    /// cooldown. Rethrows `op`'s error; on a rate-limit error it arms/grows the
    /// backoff first so subsequent calls hold off.
    func run<T: Sendable>(_ lane: Lane, _ op: @Sendable () async throws -> T) async throws -> T {
        await acquire(lane)
        defer { release(lane) }
        await waitOutCooldown()
        do {
            let result = try await op()
            backoff = 0                     // success clears the escalation
            return result
        } catch {
            if (error as? GroqError)?.isRateLimited == true { armBackoff() }
            throw error
        }
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

    private func armBackoff() {
        backoff = backoff == 0 ? Self.firstBackoff : min(backoff * 2, Self.maxBackoff)
        pausedUntil = Date().addingTimeInterval(backoff)
    }
}
