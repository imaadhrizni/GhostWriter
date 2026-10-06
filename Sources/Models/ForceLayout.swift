import Foundation

// MARK: - Force Layout
//
// A small force-directed layout for the Catalog Network: nodes repel one
// another, edges act as springs, and a weak pull toward the centre keeps
// disconnected clusters from drifting off. Pinned nodes stay where the user put
// them and still push others away.
//
// Pure and deterministic — a node's starting position comes from a stable hash
// of its id (not `Hasher`, which is randomised per launch), so the same Catalog
// settles to the same picture every time and tests are repeatable. At the
// Catalog's scale (hundreds of nodes) the straightforward O(n²) repulsion is
// well inside a frame's budget.

struct ForceLayout {

    struct Link {
        var a: Int
        var b: Int
        var rest: Double       // spring length
        var strength: Double
    }

    private(set) var ids: [String] = []
    private(set) var x: [Double] = []
    private(set) var y: [Double] = []
    private var vx: [Double] = []
    private var vy: [Double] = []
    private(set) var radius: [Double] = []
    private(set) var pinned: [Bool] = []
    private(set) var index: [String: Int] = [:]

    /// Simulation "temperature" — 1 is lively, below `restThreshold` it has settled.
    private(set) var alpha: Double = 1
    static let restThreshold = 0.02
    /// Strength of the push between any two nodes (higher = more spread out).
    static let repulsion = 5200.0
    /// Minimum empty space kept between two nodes' edges, room for a label.
    static let clearance = 22.0

    var isSettled: Bool { alpha < Self.restThreshold }

    // MARK: Population

    /// Replace the set of bodies, keeping the position of any id that was already
    /// here (or in `saved`), and placing a new one beside `anchor(id)` if it has a
    /// laid-out neighbour, else at its hashed start position.
    mutating func sync(_ bodies: [(id: String, radius: Double)],
                       saved: [String: (x: Double, y: Double, pinned: Bool)] = [:],
                       anchor: (String) -> String? = { _ in nil }) {
        let old = (0..<ids.count).reduce(into: [String: (Double, Double, Bool)]()) { $0[ids[$1]] = (x[$1], y[$1], pinned[$1]) }
        ids = bodies.map(\.id)
        radius = bodies.map(\.radius)
        index = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        x = []; y = []; pinned = []
        for id in ids {
            if let o = old[id] { x.append(o.0); y.append(o.1); pinned.append(o.2) }
            else if let s = saved[id] { x.append(s.x); y.append(s.y); pinned.append(s.pinned) }
            else if let a = anchor(id), let near = old[a] {
                let h = Self.hash(id)
                x.append(near.0 + Self.unit(h, 0) * 36 - 18); y.append(near.1 + Self.unit(h, 1) * 36 - 18); pinned.append(false)
            } else {
                let h = Self.hash(id), angle = Self.unit(h, 0) * 2 * .pi, r = 80 + Self.unit(h, 1) * 220
                x.append(cos(angle) * r); y.append(sin(angle) * r); pinned.append(false)
            }
        }
        vx = Array(repeating: 0, count: ids.count); vy = vx
    }

    mutating func reheat(_ a: Double = 0.7) { alpha = max(alpha, a) }
    mutating func setPinned(_ i: Int, _ value: Bool) { if pinned.indices.contains(i) { pinned[i] = value } }
    mutating func move(_ i: Int, to p: (x: Double, y: Double)) { if x.indices.contains(i) { x[i] = p.x; y[i] = p.y; vx[i] = 0; vy[i] = 0 } }

    /// Scatter everything (keeping nothing pinned) and run hot — "Reset layout".
    mutating func scramble() {
        for i in ids.indices {
            let h = Self.hash(ids[i] + "#reset"), angle = Self.unit(h, 0) * 2 * .pi, r = 60 + Self.unit(h, 1) * 200
            x[i] = cos(angle) * r; y[i] = sin(angle) * r; vx[i] = 0; vy[i] = 0; pinned[i] = false
        }
        alpha = 1
    }

    // MARK: Simulation

    /// Advance one step over the `active` bodies and `links` between them.
    mutating func tick(active: [Int], links: [Link], fixed: Int? = nil) {
        for ai in 0..<active.count {
            let i = active[ai]
            for bi in (ai + 1)..<max(ai + 1, active.count) {
                let j = active[bi]
                let dx = x[j] - x[i], dy = y[j] - y[i]
                let d2 = dx * dx + dy * dy + 0.5, d = d2.squareRoot()
                var f = Self.repulsion / d2
                // Leave room for the label under each node, not just the shape.
                let minGap = radius[i] + radius[j] + Self.clearance
                if d < minGap { f += (minGap - d) * 0.4 }          // don't overlap
                let fx = dx / d * f, fy = dy / d * f
                vx[i] -= fx; vy[i] -= fy; vx[j] += fx; vy[j] += fy
            }
        }
        for l in links {
            let dx = x[l.b] - x[l.a], dy = y[l.b] - y[l.a], d = (dx * dx + dy * dy).squareRoot() + 0.01
            let f = (d - l.rest) * l.strength, fx = dx / d * f, fy = dy / d * f
            vx[l.a] += fx; vy[l.a] += fy; vx[l.b] -= fx; vy[l.b] -= fy
        }
        for i in active {
            vx[i] -= x[i] * 0.003; vy[i] -= y[i] * 0.003             // gentle pull to the centre
            if pinned[i] || i == fixed { vx[i] = 0; vy[i] = 0; continue }
            vx[i] *= 0.78; vy[i] *= 0.78
            x[i] += vx[i] * alpha; y[i] += vy[i] * alpha
        }
        alpha *= 0.985
    }

    /// Run to rest in one go (used for the first paint and under Reduce Motion).
    mutating func settle(active: [Int], links: [Link], maxTicks: Int = 420) {
        alpha = 1
        for _ in 0..<maxTicks where !isSettled { tick(active: active, links: links) }
        alpha = min(alpha, Self.restThreshold / 2)
    }

    // MARK: Deterministic randomness

    /// FNV-1a — stable across launches, unlike `Hasher`.
    static func hash(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return h
    }
    /// A repeatable value in 0..<1 derived from a hash and a lane.
    static func unit(_ h: UInt64, _ lane: UInt64) -> Double {
        var z = h &+ (lane &+ 1) &* 0x9E3779B97F4A7C15
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }
}
