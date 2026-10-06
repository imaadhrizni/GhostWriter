import SwiftUI
import AppKit

// MARK: - Catalog Network
//
// The Catalog's relationship graph: organisations, projects, people, tags (and,
// on request, notes) as nodes, the links between them as edges, laid out by a
// force simulation. Click a node to open its editor in the detail pane;
// double-click to focus on it; shift-click a second node to trace the shortest
// path between them; drag a node to pin it. Logic lives in `CatalogGraph`
// (what's linked), `ForceLayout` (where it sits) and `NetworkModel` (state);
// this file is drawing and gestures.

// MARK: Presentation helpers

extension CatalogGraph.Kind {
    /// The Catalog section whose editor shows this kind of node.
    var section: CatalogSection {
        switch self {
        case .org: return .organisations
        case .project: return .projects
        case .person: return .people
        case .tag: return .tags
        case .note: return .notes
        }
    }
    /// A node takes its section's sidebar tint, so its colour reads as where it lives.
    var color: Color { section.tint }
}

// MARK: Root

struct CatalogNetworkView: View {
    @ObservedObject var store: CatalogStore
    /// Reports the selected node's section + entity id (nil, nil when cleared) so
    /// the Catalog's detail pane can show its editor — same contract as Map.
    let onSelect: (CatalogSection?, String?) -> Void
    let onOpenNote: (String) -> Void
    @StateObject private var model = NetworkModel()

    var body: some View {
        VStack(spacing: 0) {
            NetworkToolbar(model: model)
            Divider()
            ZStack {
                if model.isEmpty {
                    ContentUnavailableView("Nothing to connect yet", systemImage: "network",
                        description: Text("Add organisations, projects and people to the Catalog and link notes to them — the network draws itself from those links."))
                } else {
                    NetworkCanvas(model: model, clock: model.clock, onOpenNote: onOpenNote)
                    NetworkOverlays(model: model, onOpenNote: onOpenNote)
                }
            }
        }
        .onAppear { model.rebuild(from: store) }
        .onDisappear { model.stop() }
        // The store republishes on every edit; wait for the burst to finish, then
        // rebuild once (positions are kept by id, so nothing jumps).
        .onReceive(store.objectWillChange.debounce(for: .milliseconds(300), scheduler: RunLoop.main)) { _ in
            model.rebuild(from: store)
        }
        .onChange(of: model.selected) { _, id in
            if let id, let n = model.graph.node(id) { onSelect(n.kind.section, n.refID) } else { onSelect(nil, nil) }
        }
    }
}

// MARK: Toolbar

private struct NetworkToolbar: View {
    @ObservedObject var model: NetworkModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Row 1 — find, then the view options.
            HStack(spacing: 10) {
                search
                Spacer(minLength: 0)
                Picker("Highlight", selection: $model.overlay) {
                    ForEach(NetworkOverlay.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu).controlSize(.small).fixedSize()
                .help("Connectors: people who appear across organisations. Dormant: accounts with no recent note.")

                Picker("Notes from", selection: $model.range) {
                    ForEach(NetworkRange.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu).controlSize(.small).fixedSize()
                .help("Dim notes older than this")

                Button { model.resetLayout() } label: { Image(systemName: "arrow.triangle.2.circlepath") }
                    .controlSize(.small).help("Reset layout — forget pinned positions and re-run it")
            }
            // Row 2 — what to show; wraps when the column is narrow.
            FlowLayout(spacing: 6) {
                ForEach(CatalogGraph.Kind.allCases) { kind in
                    Toggle(isOn: Binding(get: { model.kinds.contains(kind) }, set: { _ in model.toggle(kind) })) {
                        HStack(spacing: 5) {
                            Circle().fill(kind.color).frame(width: 8, height: 8)
                            Text(kind.plural)
                            Text("\(model.count(kind))").foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    .toggleStyle(.button).controlSize(.small)
                    .help("Show or hide \(kind.plural.lowercased())")
                }
                Toggle("Derived links", isOn: Binding(get: { model.derived }, set: { model.setDerived($0) }))
                    .toggleStyle(.button).controlSize(.small)
                    .help("Links computed from notes: people and tags to the organisations they appear with")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(.bar)
    }

    private var search: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find a node", text: $model.query)
                .textFieldStyle(.plain)
                .onSubmit { model.jumpToQuery() }
            if !model.query.isEmpty {
                Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.secondary.opacity(0.25)))
        .frame(minWidth: 120, idealWidth: 200, maxWidth: 240)
    }
}

// MARK: Overlays (mode bar, selection card, legend, zoom)

private struct NetworkOverlays: View {
    @ObservedObject var model: NetworkModel
    let onOpenNote: (String) -> Void

    var body: some View {
        VStack {
            if let bar = modeBar { bar }
            HStack(alignment: .top) {
                Spacer()
                if let id = model.selected, let node = model.graph.node(id) {
                    NetworkSelectionCard(model: model, node: node, onOpenNote: onOpenNote)
                }
            }
            Spacer()
            HStack(alignment: .bottom) {
                legend
                Spacer()
                zoomControls
            }
        }
        .padding(12)
        .allowsHitTesting(true)
    }

    @ViewBuilder private var modeBar: (some View)? {
        if let f = model.focus, let n = model.graph.node(f) {
            bar {
                Text("Focused on **\(n.name)**")
                Stepper("within \(model.depth) step\(model.depth == 1 ? "" : "s")", value: $model.depth, in: 1...3)
                    .fixedSize()
                Button("Show everything") { model.focusOn(nil) }
            }
        } else if let from = model.pathFrom, let n = model.graph.node(from) {
            bar { Text("Tracing from **\(n.name)** — click the node to trace to."); Button("Cancel") { model.clearPath() } }
        } else if let p = model.path, let a = model.graph.node(p.first ?? ""), let b = model.graph.node(p.last ?? "") {
            bar {
                Text("**\(a.name)** → **\(b.name)** in \(p.count - 1) step\(p.count == 2 ? "" : "s")")
                Button("Clear") { model.clearPath() }
            }
        } else if let note = model.notice {
            bar { Text(note); Button("Dismiss") { model.dismissNotice() } }
        }
    }

    private func bar<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 12) { content() }
            .font(.callout)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Capsule().fill(Color.accentColor.opacity(0.14)))
            .overlay(Capsule().stroke(Color.accentColor.opacity(0.4)))
    }

    private var legend: some View {
        HStack(spacing: 10) {
            ForEach(CatalogGraph.Kind.allCases) { k in
                HStack(spacing: 4) { Circle().fill(k.color).frame(width: 8, height: 8); Text(k.singular) }
            }
            HStack(spacing: 4) { Circle().stroke(Color.yellow, lineWidth: 2).frame(width: 9, height: 9); Text("Connector") }
            HStack(spacing: 4) { Circle().stroke(Color.secondary, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2])).frame(width: 9, height: 9); Text("Dormant") }
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8).fill(.regularMaterial))
        .accessibilityHidden(true)
    }

    private var zoomControls: some View {
        VStack(spacing: 0) {
            Button { model.zoomCentered(1.25) } label: { Image(systemName: "plus").frame(width: 26, height: 24) }
            Divider().frame(width: 26)
            Button { model.zoomCentered(1 / 1.25) } label: { Image(systemName: "minus").frame(width: 26, height: 24) }
            Divider().frame(width: 26)
            Button { model.fit() } label: { Image(systemName: "arrow.up.left.and.down.right.magnifyingglass").frame(width: 26, height: 24) }
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 8).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))
        .help("Zoom in · zoom out · fit to window")
    }
}

private struct NetworkSelectionCard: View {
    @ObservedObject var model: NetworkModel
    let node: CatalogGraph.Node
    let onOpenNote: (String) -> Void

    private var links: [(node: CatalogGraph.Node, edge: CatalogGraph.Edge)] {
        model.graph.connections(of: node.id).filter { model.kinds.contains($0.node.kind) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(node.kind.color).frame(width: 9, height: 9)
                Text(node.kind.singular.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                if node.isConnector { badge("Connector", .yellow) }
                if node.isDormant { badge("Dormant", .gray) }
                Spacer()
                Button { model.select(nil) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            Text(node.name).font(.headline).lineLimit(3)
            Text(summary).font(.caption).foregroundStyle(.secondary)

            HStack(spacing: 6) {
                Button(model.focus == node.id ? "Exit focus" : "Focus") { model.focusOn(model.focus == node.id ? nil : node.id) }
                Button("Trace path…") { model.beginPath() }
                Button(model.isPinned(node.id) ? "Unpin" : "Pin") { model.togglePin(node.id) }
                if node.kind == .note { Button("Open") { onOpenNote(node.refID) } }
            }
            .controlSize(.small)

            if !links.isEmpty {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(links.prefix(40), id: \.node.id) { item in
                            Button { model.click(item.node.id); model.center(on: item.node.id) } label: {
                                HStack(spacing: 6) {
                                    Circle().fill(item.node.kind.color).frame(width: 7, height: 7)
                                    Text(item.node.name).lineLimit(1)
                                    Spacer(minLength: 4)
                                    if item.edge.kind == .derived {
                                        Text("via notes ×\(item.edge.weight)").font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).font(.caption)
                        }
                    }
                }
                .frame(maxHeight: 150)
            }
        }
        .padding(12)
        .frame(width: 250, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.25)))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
    }

    private var summary: String {
        var parts: [String] = []
        if let d = node.detail, !d.isEmpty { parts.append(d) }
        if node.kind == .project, let c = node.valueCents, c > 0 { parts.append(String(format: "$%.0fk", Double(c) / 100_000)) }
        if node.kind != .note, node.kind != .tag || node.noteCount > 0 {
            parts.append("\(node.noteCount) note\(node.noteCount == 1 ? "" : "s")")
        }
        if let d = node.lastNoteDaysAgo { parts.append(node.kind == .note ? "\(d) d ago" : "last \(d) d ago") }
        return parts.joined(separator: " · ")
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.18))).foregroundStyle(color == .gray ? .secondary : color)
    }
}

// MARK: Canvas

private struct NetworkCanvas: View {
    @ObservedObject var model: NetworkModel
    @ObservedObject var clock: NetworkFrameClock            // redraw trigger only
    let onOpenNote: (String) -> Void

    @State private var pointerActive = false
    @State private var lastMagnification: CGFloat = 1

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in draw(&ctx, size) }
                .gesture(dragGesture)
                .simultaneousGesture(MagnifyGesture()
                    .onChanged { v in
                        model.zoomCentered(v.magnification / lastMagnification); lastMagnification = v.magnification
                    }
                    .onEnded { _ in lastMagnification = 1 })
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p): model.setHovered(model.node(at: p))
                    case .ended: model.setHovered(nil)
                    }
                }
                .background(ScrollCatcher { p, delta, precise, command in
                    if precise && !command { model.pan(by: delta) }
                    else { model.zoom(at: p, by: exp(delta.height * 0.01)) }
                    return true
                })
                .focusable()
                .onKeyPress { press in handleKey(press) }
                .onAppear { model.sizeChanged(geo.size) }
                .onChange(of: geo.size) { _, s in model.sizeChanged(s) }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Relationship graph")
                .accessibilityChildren {
                    ForEach(model.visibleNodes) { n in
                        Button("\(n.kind.singular) \(n.name), \(n.noteCount) notes") { model.click(n.id) }
                    }
                }
        }
        .clipped()
    }

    // MARK: Input

    /// Forwards to the model, which owns click/drag/pan/double-click behaviour.
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if !pointerActive { pointerActive = true; model.pointerDown(v.startLocation) }
                model.pointerMoved(v.location)
            }
            .onEnded { _ in
                pointerActive = false
                if case .openNote(let id) = model.pointerUp(shift: NSEvent.modifierFlags.contains(.shift)) { onOpenNote(id) }
            }
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .escape:     model.focusOn(nil); model.clearPath(); model.select(nil)
        case .leftArrow:  model.pan(by: CGSize(width: 40, height: 0))
        case .rightArrow: model.pan(by: CGSize(width: -40, height: 0))
        case .upArrow:    model.pan(by: CGSize(width: 0, height: 40))
        case .downArrow:  model.pan(by: CGSize(width: 0, height: -40))
        default:
            switch press.characters {
            case "+", "=": model.zoomCentered(1.2)
            case "-":      model.zoomCentered(1 / 1.2)
            case "0":      model.fit()
            default:       return .ignored
            }
        }
        return .handled
    }

    // MARK: Drawing

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize) {
        _ = clock.frame
        let bg = Color(nsColor: .textBackgroundColor)
        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(bg))
        drawGrid(&ctx, size)

        let edges = model.visibleEdges
        let activeID = model.hovered ?? model.selected
        let pathSet = Set(model.path ?? [])
        var pathEdges = Set<String>()
        if let p = model.path { for k in 1..<max(p.count, 1) { pathEdges.insert(p[k - 1] + ">" + p[k]); pathEdges.insert(p[k] + ">" + p[k - 1]) } }
        var near: Set<String>?
        if model.path == nil, let a = activeID {
            var s: Set<String> = [a]
            for e in edges.map(\.edge) where e.a == a || e.b == a { s.insert(e.a); s.insert(e.b) }
            near = s
        }
        let q = model.query.trimmingCharacters(in: .whitespaces).lowercased()
        let days = model.range.days

        func alpha(_ n: CatalogGraph.Node) -> Double {
            var a = 1.0
            if model.path != nil { a = pathSet.contains(n.id) ? 1 : 0.12 }
            else if let near { a = near.contains(n.id) ? 1 : 0.16 }
            if n.kind == .note, let d = days, (n.lastNoteDaysAgo ?? 0) > d { a = min(a, 0.14) }
            if !q.isEmpty, !n.name.lowercased().contains(q) { a = min(a, 0.2) }
            return a
        }

        // Edges
        for (e, ia, ib) in edges {
            guard let na = model.graph.node(e.a), let nb = model.graph.node(e.b) else { continue }
            let p = model.toScreen(ia), r = model.toScreen(ib)
            let onPath = pathEdges.contains(e.a + ">" + e.b)
            var a = min(alpha(na), alpha(nb))
            if model.path != nil, !onPath { a = 0.08 }
            if let near, model.path == nil, !(near.contains(e.a) && near.contains(e.b)) { a = 0.07 }
            var path = Path(); path.move(to: p); path.addLine(to: r)
            let highlighted = near.map { $0.contains(e.a) && $0.contains(e.b) } ?? false
            let color: Color = onPath ? .accentColor : (highlighted ? .primary : .secondary)
            let width = onPath ? 3.2 : (e.kind == .derived ? 1 + Double(min(e.weight, 3)) * 0.5 : 1.1) * Double(max(0.8, min(model.scale, 1.4)))
            // Derived links are the busiest layer, so they sit back until you point at one.
            let base = e.kind == .derived ? (highlighted ? 0.9 : 0.45) : 0.9
            ctx.stroke(path, with: .color(color.opacity(a * base)),
                       style: StrokeStyle(lineWidth: width, lineCap: .round, dash: e.kind == .derived ? [5, 5] : []))
        }

        // Nodes + labels
        var labels: [(CatalogGraph.Node, CGPoint, CGFloat, Double)] = []
        for i in model.drawOrder {
            guard let n = model.graph.node(model.layout.ids[i]) else { continue }
            let c = model.toScreen(i), r = CGFloat(n.radius) * model.scale, a = alpha(n)
            drawNode(&ctx, n, c, r, a, bg)
            if model.overlay == .connectors, n.isConnector { ring(&ctx, c, r + 5, .yellow, 3, a) }
            if model.overlay == .dormant, n.isDormant { ring(&ctx, c, r + 6, .secondary, 2, a, dash: [4, 3]) }
            if n.id == model.selected || n.id == model.pathFrom { ring(&ctx, c, r + 8, .accentColor, 2.5, 1) }
            if model.isPinned(n.id) {
                let pin = CGPoint(x: c.x + r * 0.75, y: c.y - r * 0.75)
                ctx.fill(Path(ellipseIn: CGRect(x: pin.x - 3.4, y: pin.y - 3.4, width: 6.8, height: 6.8)), with: .color(bg))
                ctx.fill(Path(ellipseIn: CGRect(x: pin.x - 2, y: pin.y - 2, width: 4, height: 4)), with: .color(.primary))
            }
            let always = n.kind == .org || n.kind == .project || n.kind == .person
            let relevant = (near?.contains(n.id) ?? false) || pathSet.contains(n.id) || n.id == model.selected
                || (!q.isEmpty && n.name.lowercased().contains(q))
            if (always && model.scale > 0.55) || relevant || model.scale > 1.5 { labels.append((n, c, r, a)) }
        }
        for (n, c, r, a) in labels {
            let name = n.name.count > 26 ? String(n.name.prefix(25)) + "…" : n.name
            let size = 11.5 * min(max(model.scale, 0.8), 1.25)
            let font = Font.system(size: size, weight: n.kind == .org ? .semibold : .medium)
            let at = CGPoint(x: c.x, y: c.y + r + 6)
            var lc = ctx; lc.opacity = max(a, 0.25)
            for off in [CGPoint(x: -1.3, y: 0), CGPoint(x: 1.3, y: 0), CGPoint(x: 0, y: -1.3), CGPoint(x: 0, y: 1.3)] {
                lc.draw(Text(name).font(font).foregroundColor(bg), at: CGPoint(x: at.x + off.x, y: at.y + off.y), anchor: .top)
            }
            lc.draw(Text(name).font(font).foregroundColor(.primary), at: at, anchor: .top)
        }
    }

    private func drawNode(_ ctx: inout GraphicsContext, _ n: CatalogGraph.Node, _ c: CGPoint, _ r: CGFloat, _ a: Double, _ bg: Color) {
        var nc = ctx; nc.opacity = a
        let color = n.kind.color, halo = StrokeStyle(lineWidth: 2)
        switch n.kind {
        case .org:
            let p = Path(roundedRect: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2), cornerRadius: r * 0.32)
            nc.fill(p, with: .color(color)); nc.stroke(p, with: .color(bg), style: halo)
        case .tag:
            var p = Path(); let k = r * 1.1
            p.move(to: CGPoint(x: c.x, y: c.y - k)); p.addLine(to: CGPoint(x: c.x + k, y: c.y))
            p.addLine(to: CGPoint(x: c.x, y: c.y + k)); p.addLine(to: CGPoint(x: c.x - k, y: c.y)); p.closeSubpath()
            nc.fill(p, with: .color(color)); nc.stroke(p, with: .color(bg), style: halo)
        default:
            let p = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            nc.fill(p, with: .color(color)); nc.stroke(p, with: .color(bg), style: halo)
        }
        if n.kind == .project {                                   // stage ring: won green, lost red, open orange
            let stage: Color = n.stage == "won" ? .green : n.stage == "lost" ? .red : .orange
            nc.stroke(Path(ellipseIn: CGRect(x: c.x - r - 2.6, y: c.y - r - 2.6, width: (r + 2.6) * 2, height: (r + 2.6) * 2)),
                      with: .color(stage), style: StrokeStyle(lineWidth: n.stage == "open" ? 1.2 : 2.4))
        }
    }

    private func ring(_ ctx: inout GraphicsContext, _ c: CGPoint, _ r: CGFloat, _ color: Color, _ w: CGFloat, _ a: Double, dash: [CGFloat] = []) {
        var rc = ctx; rc.opacity = a
        rc.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                  with: .color(color), style: StrokeStyle(lineWidth: w, dash: dash))
    }

    /// A faint grid so panning and zooming read as movement.
    private func drawGrid(_ ctx: inout GraphicsContext, _ size: CGSize) {
        var step = 48 * model.scale; if step < 18 { step *= 3 }
        var p = Path()
        var x = model.offset.x.truncatingRemainder(dividingBy: step); if x < 0 { x += step }
        while x < size.width { p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height)); x += step }
        var y = model.offset.y.truncatingRemainder(dividingBy: step); if y < 0 { y += step }
        while y < size.height { p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y)); y += step }
        ctx.stroke(p, with: .color(.secondary.opacity(0.10)), lineWidth: 1)
    }
}

// MARK: Scroll wheel

/// Delivers scroll-wheel events over its bounds. The view itself is transparent to
/// mouse events (so clicks and drags reach the canvas); a local event monitor
/// picks up the scroll. Trackpad scrolling pans; a mouse wheel (or ⌘-scroll) zooms.
private struct ScrollCatcher: NSViewRepresentable {
    /// (location in view, scroll delta, was a trackpad, ⌘ held) → handled
    var onScroll: (CGPoint, CGSize, Bool, Bool) -> Bool

    func makeNSView(context: Context) -> CatcherView { let v = CatcherView(); v.handler = onScroll; return v }
    func updateNSView(_ v: CatcherView, context: Context) { v.handler = onScroll }

    final class CatcherView: NSView {
        var handler: ((CGPoint, CGSize, Bool, Bool) -> Bool)?
        private var monitor: Any?
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let w = self.window, event.window === w else { return event }
                let p = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(p) else { return event }
                let handled = self.handler?(p, CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY),
                                            event.hasPreciseScrollingDeltas, event.modifierFlags.contains(.command)) ?? false
                return handled ? nil : event
            }
        }
        deinit { if let m = monitor { NSEvent.removeMonitor(m) } }
    }
}
