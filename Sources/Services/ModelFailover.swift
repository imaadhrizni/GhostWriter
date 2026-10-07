import Foundation

// MARK: - Model Failover
//
// When a model is out of capacity — rate-limited, its daily quota spent, or the
// provider erroring — try the next model in the task's chain instead of failing
// the feature or waiting out a long window. Groq's limits are per model, so
// models that are idle can serve the work a saturated one can't.
//
//   • `ModelResolver.failoverChain` decides *which* models, in order, per role.
//   • `AIGate.pickModel` picks the first one with room right now (or soon).
//   • This runs the attempt, and on a *capacity* fault moves to the next one.
//
// Only capacity faults fail over. A bad request, an auth error, or an unparsable
// reply would fail identically everywhere — retrying them across models would
// just multiply requests. Decommissioned-model faults are ModelResolver's job.

enum ModelFailover {

    /// Whether `error` means "this model can't take the work right now" — the
    /// only condition that justifies trying a different one.
    static func isCapacityFault(_ error: Error) -> Bool {
        guard let groq = error as? GroqError else { return false }
        if groq.isRateLimited { return true }
        if case .apiError(let code, _) = groq { return (500...599).contains(code) }
        return false
    }

    /// A switch must save at least this long. Moving to another model costs
    /// consistency (and a possible quality step down), so it only wins when the
    /// preferred model would keep us waiting meaningfully longer.
    static let switchPenalty: TimeInterval = 10

    /// The wait the server asked for, if it named one (429 `retry-after`).
    static func retryAfter(of error: Error) -> TimeInterval? {
        if case .rateLimited(let after, _)? = error as? GroqError { return after }
        return nil
    }

    /// Run `attempt` against the best model in `chain`. On a capacity fault it
    /// decides **wait or switch**: if the best alternative would start at least
    /// `switchPenalty` sooner than the preferred model's own `retry-after`, move
    /// to it; otherwise stay and wait it out (retrying inside the gate) — so a
    /// burst where every model is briefly saturated doesn't cascade the work down
    /// to the last, least-preferred model. A fault with no stated wait (a 5xx) has
    /// nothing to wait for, so it switches. If waiting on the preferred model
    /// still fails, the remaining models are tried in order.
    /// - Parameters:
    ///   - chain: candidate model ids, preferred first (non-empty)
    ///   - estimate: rough tokens the call needs, used to pick a model with room
    ///   - source: the feature label, for the log
    ///   - attempt: receives the model and whether it may wait out a rate limit
    ///     (true when nothing else is left to try, or once we've chosen to wait)
    static func run<T>(chain: [String], estimate: Int, source: String,
                       attempt: (_ model: String, _ mayWait: Bool) async throws -> T) async throws -> T {
        precondition(!chain.isEmpty, "ModelFailover needs at least one model")
        var candidates = chain
        var current = candidates.count > 1
            ? await AIGate.shared.pickModel(candidates, estimate: estimate)
            : candidates[0]
        var waiting = false
        while true {
            let others = candidates.filter { $0 != current }
            do {
                return try await attempt(current, others.isEmpty || waiting)
            } catch {
                guard isCapacityFault(error), !others.isEmpty else { throw error }

                if !waiting, let hinted = retryAfter(of: error) {
                    let alt = await AIGate.shared.plan(others, estimate: estimate, tolerance: 0.5)
                    if alt.wait + switchPenalty >= hinted {
                        Log.api.info("⏳ \(source): \(current) is \(Int(hinted.rounded()))s from free and \(alt.model) isn't much sooner (\(Int(alt.wait.rounded()))s) — waiting rather than switching")
                        waiting = true
                        continue
                    }
                }
                // Switch: the alternative is meaningfully sooner, there's no wait to
                // sit out (provider error), or waiting here already failed.
                candidates.removeAll { $0 == current }
                current = await AIGate.shared.pickModel(candidates, estimate: estimate)
                waiting = false
                Log.api.warning("⇄ \(source): switching to \(current) (\(candidates.count - 1) other model(s) left)")
            }
        }
    }
}
