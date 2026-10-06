import SwiftUI
import AppKit
import Combine

// MARK: - Network Model
//
// State behind the Catalog's Network section: the graph and its layout, the
// filters (which node kinds, derived links, a highlight overlay, a date range),
// what's selected / hovered / focused / being traced, and the camera (pan +
// zoom). It owns the simulation loop and remembers pinned node positions
// between launches.
//
// Animation ticks go through a separate `NetworkFrameClock`, so the canvas
// redraws every frame without re-rendering the toolbar and inspector, which
// observe this object and only change when the user does something.

/// Bumped once per simulation step; only the canvas observes it.
final class NetworkFrameClock: ObservableObject {
    @Published private(set) var frame = 0
    func bump() { frame &+= 1 }
}

/// How far back notes are shown at full strength (older ones are dimmed).
enum NetworkRange: String, CaseIterable, Identifiable {
    case all = "All time", days90 = "Last 90 days", days30 = "Last 30 days"
    var id: String { rawValue }
    var days: Int? { self == .all ? nil : (self == .days90 ? 90 : 30) }
}

/// A highlight layer drawn over the graph.
enum NetworkOverlay: String, CaseIterable, Identifiable {
    case none = "None", connectors = "Connectors", dormant = "Dormant accounts"
    var id: String { rawValue }
}

@MainActor
final class NetworkModel: ObservableObject {

    // MARK: Data
    private(set) var graph = CatalogGraph()
    private(set) var layout = ForceLayout()
    let clock = NetworkFrameClock()

    // MARK: Filters
    @Published var kinds: Set<CatalogGraph.Kind>
    @Published var derived: Bool
    @Published var overlay: NetworkOverlay = .none
    @Published var range: NetworkRange = .all
    @Published var query = ""

    // MARK: Interaction
    @Published private(set) var selected: String?
    @Published private(set) var hovered: String?
    @Published private(set) var focus: String?
    @Published var depth = 1 { didSet { if oldValue != depth { refresh(reheat: 0.8, refit: true) } } }
    @Published private(set) var path: [String]?
    @Published private(set) var pathFrom: String?
    @Published private(set) var notice: String?

    // MARK: Camera
    var scale: CGFloat = 1
    var offset: CGPoint = .zero
    var viewSize: CGSize = .zero

    // MARK: Internals
    private var focusSet: Set<String>?
    private var active: [Int] = []                       // layout indices on screen
    private var links: [ForceLayout.Link] = []
    private var simTask: Task<Void, Never>?
    private var dragging: Int?
    private var hasFitted = false
    private var savedPins: [String: [Double]] = [:]
    private let pinsURL = AppPaths.support().appendingPathComponent("NetworkLayout.json")

    private var settings: AppSettings { .shared }
    var animates: Bool {
        settings.networkAnimate && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    init() {
        let s = AppSettings.shared
        var k: Set<CatalogGraph.Kind> = [.org, .project, .person]
        if s.networkShowTags { k.insert(.tag) }
        if s.networkShowNotes { k.insert(.note) }
        kinds = k
        derived = s.networkDerivedLinks
        if let data = try? Data(contentsOf: pinsURL),
           let decoded = try? JSONDecoder().decode([String: [Double]].self, from: data) { savedPins = decoded }
    }

    var visibility: CatalogGraph.Visibility { .init(kinds: kinds, derived: derived) }
    var isEmpty: Bool { graph.nodes.isEmpty }

    // MARK: Build

    /// (Re)build from the live Catalog, keeping positions of nodes that persist.
    func rebuild(from store: CatalogStore) {
        let known = Set(layout.ids)
        graph = CatalogGraph(store.graphInput(), dormantDays: settings.networkDormantDays)
        let g = graph
        let pins = savedPins.mapValues { (x: $0[0], y: $0[1], pinned: true) }
        layout.sync(graph.nodes.map { ($0.id, $0.radius) }, saved: pins,
                    anchor: { id in g.connections(of: id).first { known.contains($0.node.id) }?.node.id })
        if let s = selected, graph.node(s) == nil { selected = nil }
        if let f = focus, graph.node(f) == nil { focus = nil }
        path = nil; pathFrom = nil
        refresh(reheat: known.isEmpty ? 1 : 0.5, refit: !hasFitted)
    }

    /// Recompute what's on screen (kinds / focus) and rewire the springs.
    private func refresh(reheat a: Double, refit: Bool = false) {
        focusSet = focus.map { graph.ego(of: $0, depth: depth, visibility) }
        let v = visibility
        active = graph.nodes.indices.compactMap { i in
            let n = graph.nodes[i]
            guard graph.shows(n, v), focusSet.map({ $0.contains(n.id) }) ?? true else { return nil }
            return layout.index[n.id]
        }
        let onScreen = Set(active)
        links = graph.edges.compactMap { e in
            guard graph.shows(e, v), let a = layout.index[e.a], let b = layout.index[e.b],
                  onScreen.contains(a), onScreen.contains(b) else { return nil }
            let s = e.kind.spring
            return .init(a: a, b: b, rest: s.rest, strength: s.strength)
        }
        if animates {
            layout.reheat(a)
            if !hasFitted { layout.settle(active: active, links: links); layout.reheat(0.3) }
            startSimulation()
        } else {
            layout.settle(active: active, links: links)
        }
        if refit && !viewSize.equalTo(.zero) { fit(); hasFitted = true }
        clock.bump()
        objectWillChange.send()
    }

    // MARK: Simulation

    private func startSimulation() {
        guard simTask == nil else { return }
        simTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, !self.layout.isSettled {
                self.layout.tick(active: self.active, links: self.links, fixed: self.dragging)
                self.layout.tick(active: self.active, links: self.links, fixed: self.dragging)
                self.clock.bump()
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
            self?.simTask = nil
        }
    }
    func stop() { simTask?.cancel(); simTask = nil; persistPins() }

    // MARK: Camera

    func toScreen(_ i: Int) -> CGPoint { CGPoint(x: layout.x[i] * scale + offset.x, y: layout.y[i] * scale + offset.y) }
    func toWorld(_ p: CGPoint) -> (x: Double, y: Double) { (Double((p.x - offset.x) / scale), Double((p.y - offset.y) / scale)) }

    func fit() {
        guard !active.isEmpty, viewSize.width > 10 else { return }
        var x0 = Double.infinity, y0 = Double.infinity, x1 = -Double.infinity, y1 = -Double.infinity
        for i in active {
            x0 = min(x0, layout.x[i] - layout.radius[i]); x1 = max(x1, layout.x[i] + layout.radius[i])
            y0 = min(y0, layout.y[i] - layout.radius[i]); y1 = max(y1, layout.y[i] + layout.radius[i] + 18)
        }
        let pad = 60.0
        let k = min((viewSize.width - pad * 2) / max(x1 - x0, 80), (viewSize.height - pad * 2) / max(y1 - y0, 80), 1.6)
        scale = CGFloat(max(0.2, k))
        offset = CGPoint(x: viewSize.width / 2 - CGFloat((x0 + x1) / 2) * scale, y: viewSize.height / 2 - CGFloat((y0 + y1) / 2) * scale)
        clock.bump()
    }
    func zoom(at p: CGPoint, by factor: CGFloat) {
        let k = min(3, max(0.2, scale * factor)), f = k / scale
        offset = CGPoint(x: p.x - (p.x - offset.x) * f, y: p.y - (p.y - offset.y) * f)
        scale = k; clock.bump()
    }
    func zoomCentered(_ factor: CGFloat) { zoom(at: CGPoint(x: viewSize.width / 2, y: viewSize.height / 2), by: factor) }
    func pan(by d: CGSize) { offset.x += d.width; offset.y += d.height; clock.bump() }
    func center(on id: String) {
        guard let i = layout.index[id] else { return }
        offset = CGPoint(x: viewSize.width / 2 - CGFloat(layout.x[i]) * scale, y: viewSize.height / 2 - CGFloat(layout.y[i]) * scale)
        clock.bump()
    }

    /// The canvas reports its size; the first real size triggers the initial fit.
    func sizeChanged(_ size: CGSize) {
        viewSize = size
        if !hasFitted, !active.isEmpty, size.width > 10 { fit(); hasFitted = true } else { clock.bump() }
    }

    /// The nodes currently shown, for VoiceOver (the canvas itself isn't introspectable).
    var visibleNodes: [CatalogGraph.Node] { active.compactMap { graph.node(layout.ids[$0]) } }

    // MARK: Hit testing

    /// The visible node under `p` (screen space), nearest first.
    func node(at p: CGPoint) -> String? {
        var best: (String, CGFloat)?
        for i in active {
            let c = toScreen(i), d = hypot(c.x - p.x, c.y - p.y), r = max(CGFloat(layout.radius[i]) * scale + 5, 11)
            if d <= r, d < (best?.1 ?? .infinity) { best = (layout.ids[i], d) }
        }
        return best?.0
    }
    /// Layout indices currently on screen, drawn smallest-last so small nodes sit on top.
    var drawOrder: [Int] { active.sorted { layout.radius[$0] > layout.radius[$1] } }
    var visibleEdges: [(edge: CatalogGraph.Edge, a: Int, b: Int)] {
        let on = Set(active), v = visibility
        return graph.edges.compactMap { e in
            guard graph.shows(e, v), let a = layout.index[e.a], let b = layout.index[e.b], on.contains(a), on.contains(b) else { return nil }
            return (e, a, b)
        }
    }

    // MARK: Selection, focus, path

    func setHovered(_ id: String?) { if id != hovered { hovered = id; clock.bump() } }

    func select(_ id: String?) {
        selected = id
        if id == nil { path = nil; pathFrom = nil }
        clock.bump()
    }
    func click(_ id: String) {
        if let from = pathFrom, from != id { trace(from: from, to: id); return }
        path = nil; select(id)
    }
    func shiftClick(_ id: String) {
        if let s = selected, s != id { trace(from: s, to: id) } else { click(id) }
    }
    func beginPath() { guard let s = selected else { return }; pathFrom = s; path = nil; notice = "Click another node to trace a path."; clock.bump() }
    func trace(from a: String, to b: String) {
        pathFrom = nil; selected = b
        if let p = graph.shortestPath(from: a, to: b, visibility) { path = p; notice = nil }
        else { path = nil; notice = "No path between \(graph.node(a)?.name ?? "") and \(graph.node(b)?.name ?? "") with the current filters." }
        clock.bump()
    }
    func clearPath() { path = nil; pathFrom = nil; notice = nil; clock.bump() }
    func focusOn(_ id: String?) {
        focus = id; path = nil; pathFrom = nil
        if let id { selected = id }
        refresh(reheat: 0.9, refit: false)
        Task { @MainActor in try? await Task.sleep(nanoseconds: 260_000_000); self.fit() }
    }
    func dismissNotice() { notice = nil }

    /// Show/hide a node kind; reveal newly shown nodes beside a visible neighbour.
    func toggle(_ kind: CatalogGraph.Kind) {
        if kinds.contains(kind) { kinds.remove(kind) } else { kinds.insert(kind) }
        if let s = selected, let n = graph.node(s), !kinds.contains(n.kind) { selected = nil }
        path = nil
        refresh(reheat: 0.9, refit: false)
        Task { @MainActor in try? await Task.sleep(nanoseconds: 300_000_000); self.fit() }
    }
    func setDerived(_ on: Bool) {
        derived = on; path = nil
        refresh(reheat: 0.9, refit: false)
        Task { @MainActor in try? await Task.sleep(nanoseconds: 300_000_000); self.fit() }
    }

    /// Select the first node matching the search text (revealing its kind if hidden).
    func jumpToQuery() {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty, let hit = graph.nodes.first(where: { $0.name.lowercased().contains(q) }) else { return }
        if !kinds.contains(hit.kind) { kinds.insert(hit.kind); refresh(reheat: 0.8) }
        path = nil; select(hit.id); center(on: hit.id)
    }

    // MARK: Pointer
    //
    // The canvas's gesture only forwards to these three calls, so the whole
    // interaction — click vs drag, pan, pin-by-dragging, double-click, shift-click
    // — lives here and is testable without a window.

    enum PointerOutcome: Equatable { case none, openNote(String) }

    private var pointer: (start: CGPoint, last: CGPoint, target: String?, moved: Bool)?
    private var lastClick: (id: String, at: Date)?
    /// A press and release closer than this many points is a click, not a drag.
    private static let dragThreshold: CGFloat = 4
    private static let doubleClickInterval: TimeInterval = 0.35

    func pointerDown(_ p: CGPoint) {
        let target = node(at: p)
        pointer = (p, p, target, false)
        if let target { beginDrag(target) }
    }

    func pointerMoved(_ p: CGPoint) {
        guard var s = pointer else { return }
        if !s.moved, hypot(p.x - s.start.x, p.y - s.start.y) > Self.dragThreshold { s.moved = true }
        if s.moved {
            if s.target != nil { drag(to: p) }
            else { pan(by: CGSize(width: p.x - s.last.x, height: p.y - s.last.y)) }
            s.last = p
        }
        pointer = s
    }

    /// Finish the gesture. A press-and-release on a node selects it (or traces a
    /// path with shift / in path mode); a quick second one focuses it — or opens
    /// it, for a note. On empty space it clears the selection (unless a mode is on).
    func pointerUp(shift: Bool = false, now: Date = Date()) -> PointerOutcome {
        guard let s = pointer else { return .none }
        pointer = nil
        if s.target != nil { endDrag() }
        guard !s.moved else { return .none }
        guard let id = s.target else {
            if focus == nil, pathFrom == nil { select(nil) }
            return .none
        }
        if let last = lastClick, last.id == id, now.timeIntervalSince(last.at) < Self.doubleClickInterval {
            lastClick = nil
            if let n = graph.node(id), n.kind == .note { return .openNote(n.refID) }
            click(id); focusOn(id)
            return .none
        }
        lastClick = (id, now)
        if shift { shiftClick(id) } else { click(id) }
        return .none
    }

    // MARK: Dragging & pins

    func beginDrag(_ id: String) { dragging = layout.index[id] }
    func drag(to p: CGPoint) {
        guard let i = dragging else { return }
        layout.move(i, to: toWorld(p)); layout.setPinned(i, true)
        layout.reheat(0.5); startSimulation(); clock.bump()
    }
    func endDrag() { dragging = nil; persistPins() }
    func togglePin(_ id: String) {
        guard let i = layout.index[id] else { return }
        layout.setPinned(i, !layout.pinned[i]); persistPins(); clock.bump(); objectWillChange.send()
    }
    func isPinned(_ id: String) -> Bool { layout.index[id].map { layout.pinned[$0] } ?? false }

    func resetLayout() {
        savedPins = [:]; persistPins()
        layout.scramble()
        refresh(reheat: 1, refit: false)
        Task { @MainActor in try? await Task.sleep(nanoseconds: 400_000_000); self.fit() }
    }

    private func persistPins() {
        var out: [String: [Double]] = [:]
        for (i, id) in layout.ids.enumerated() where layout.pinned[i] { out[id] = [layout.x[i], layout.y[i]] }
        savedPins = out
        if let data = try? JSONEncoder().encode(out) { try? data.write(to: pinsURL, options: .atomic) }
    }

    // MARK: Derived presentation

    func count(_ kind: CatalogGraph.Kind) -> Int { graph.nodes.filter { $0.kind == kind }.count }
}
