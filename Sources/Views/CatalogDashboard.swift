import SwiftUI
import Charts

// MARK: - Catalog Dashboard (Sales-Engineer overview)
//
// A single at-a-glance surface built for the SE's world: POCs, open technical
// questions and commitments, competitive/product signals, engagement mix, and
// which accounts are going quiet. Everything is derived from data the app
// already captures (Catalog links, POC criteria, note sections, Keyword Radar)
// — no new input. Catalog-only figures render instantly in the KPI column; the
// note-scan insights load asynchronously in the main canvas.

// MARK: Metrics

struct DashboardMetrics {
    // Note-scan derived
    var meetingsScanned = 0
    var weekTrend: [WeekBucket] = []
    var typeMix: [LabeledCount] = []
    var funnel: [LabeledCount] = []   // technical sales-cycle stages, in order
    var recordedSeconds = 0           // summed meeting duration in the filtered set
    var scannedURLs: Set<URL> = []    // the filtered note set (for per-org counts)
    var openActions = 0
    var overdueActions = 0
    var unanswered: [OpenQuestion] = []
    var radarTop: [LabeledCount] = []

    struct WeekBucket: Identifiable { let id = UUID(); let label: String; let count: Int }
    struct LabeledCount: Identifiable { let id = UUID(); let label: String; let count: Int }
    struct OpenQuestion: Identifiable { let id = UUID(); let question: String; let title: String; let url: URL }

    /// Scan up to `limit` recent meetings for the note-derived insights. Pure +
    /// offline; safe off the main thread. `typeNames` maps a meeting-type id to
    /// its display name (built on the main actor and passed in). `since` limits
    /// to meetings on/after that day; `allowed`, when non-nil, restricts to that
    /// set of note file URLs (used by the account-scope filter).
    static func scan(limit: Int, watchlist: [String], typeNames: [String: String],
                     since: Date? = nil, allowed: Set<URL>? = nil) -> DashboardMetrics {
        var m = DashboardMetrics()
        let cal = Calendar.current
        let now = Date()
        let dayFmt = DateDisplay.posixDay   // shared locale-independent yyyy-MM-dd

        let files = NotesLibrary.meetingFiles(limit: limit).filter { f in
            if let allowed, !allowed.contains(f.url) { return false }
            if let since, let d = dayFmt.date(from: f.day), d < cal.startOfDay(for: since) { return false }
            return true
        }
        m.meetingsScanned = files.count
        m.scannedURLs = Set(files.map { $0.url })

        var weekCounts: [Int: Int] = [:]   // weeks-ago (0..5) → count
        var typeCounts: [String: Int] = [:]
        var funnelCounts: [String: Int] = [:]   // funnel-stage label → count
        var radarCounts: [String: Int] = [:]
        var open = 0, overdue = 0
        let today = cal.startOfDay(for: now)

        for f in files {
            // Trend
            if let d = dayFmt.date(from: f.day) {
                let weeks = (cal.dateComponents([.weekOfYear], from: d, to: now).weekOfYear ?? 0)
                if weeks >= 0 && weeks < 6 { weekCounts[weeks, default: 0] += 1 }
            }
            guard let text = try? String(contentsOf: f.url, encoding: .utf8) else { continue }

            // Recorded time — front-matter `duration: <n>s`.
            if let dur = FrontMatter.field("duration", in: text) {
                m.recordedSeconds += Int(dur.trimmingCharacters(in: CharacterSet(charactersIn: "s "))) ?? 0
            }

            // Meeting-type mix (front-matter id → friendly name).
            if let typeID = FrontMatter.field("gw_meeting_type", in: text) {
                let name = typeNames[typeID] ?? typeID
                typeCounts[name, default: 0] += 1
                if let stage = Self.funnelStage(for: typeID) { funnelCounts[stage.label, default: 0] += 1 }
            }

            // Action items — open + overdue.
            for item in NotesLibrary.actionItems(inFile: f.url) where !item.done {
                open += 1
                if let due = item.due, let dd = dayFmt.date(from: due.trimmingCharacters(in: .whitespaces)),
                   dd < today { overdue += 1 }
            }

            // Unanswered questions (the SE's follow-up queue).
            let title = FrontMatter.title(in: text) ?? f.displayName
            for q in Self.unansweredQuestions(in: text) {
                m.unanswered.append(.init(question: q, title: title, url: f.url))
            }

            // Competitive / product signals — scanned over the same filtered set
            // so the radar honors the time-range and account scope too.
            if !watchlist.isEmpty {
                let body = FrontMatter.body(text)
                for c in MeetingNotesWriter.mentionCounts(in: body, terms: watchlist) where c.count > 0 {
                    radarCounts[c.term, default: 0] += c.count
                }
            }
        }

        m.weekTrend = (0..<6).reversed().map { w in
            WeekBucket(label: w == 0 ? "This wk" : "-\(w)w", count: weekCounts[w] ?? 0)
        }
        m.typeMix = typeCounts.sorted { $0.value > $1.value }.map { .init(label: $0.key, count: $0.value) }
        // Funnel stays in cycle order (including empty stages) so drop-off is visible.
        m.funnel = Self.funnelOrder.map { .init(label: $0, count: funnelCounts[$0] ?? 0) }
        m.openActions = open
        m.overdueActions = overdue
        m.radarTop = radarCounts.sorted { $0.value > $1.value }.prefix(8)
            .map { .init(label: $0.key, count: $0.value) }

        return m
    }

    /// The technical sales cycle, in order — used to render the meeting-type funnel.
    static let funnelOrder = ["Discovery", "Demo", "Scoping", "Kickoff"]

    /// Map a `MeetingType` raw id to its funnel stage, or nil for non-cycle
    /// meeting types (standups, 1:1s, all-hands, general, etc.).
    static func funnelStage(for typeID: String) -> (order: Int, label: String)? {
        switch typeID {
        case "discovery":       return (0, "Discovery")
        case "solutionDemo":    return (1, "Demo")
        case "solutionScoping": return (2, "Scoping")
        case "kickoff":         return (3, "Kickoff")
        default:                return nil
        }
    }

    /// Extract the bullet questions under a "## Unanswered Questions" heading.
    private static func unansweredQuestions(in text: String) -> [String] {
        guard let range = text.range(of: "## Unanswered Questions") else { return [] }
        let after = text[range.upperBound...]
        var out: [String] = []
        for raw in after.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") || line.hasPrefix("# ") { break }   // next section
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                let q = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if !q.isEmpty { out.append(q) }
            }
        }
        return out
    }
}

// MARK: "At a glance" KPI strip (instant, catalog-only) — inside the dashboard

private struct KPIStrip: View {
    @ObservedObject var store: CatalogStore

    private var openOpps: Int { store.doc.opportunities.filter { $0.stage == .open }.count }
    private var activePOCs: Int { store.doc.opportunities.filter { !$0.pocCriteria.isEmpty }.count }
    private var pocPassRate: Double {
        let all = store.doc.opportunities.flatMap { $0.pocCriteria }
        guard !all.isEmpty else { return 0 }
        return Double(all.filter { $0.status == .pass }.count) / Double(all.count)
    }
    private var pipeline: [(String, Int)] {
        Dictionary(grouping: store.doc.opportunities.filter { $0.stage == .open && $0.valueCents != nil },
                   by: { $0.currency })
            .mapValues { $0.reduce(0) { $0 + ($1.valueCents ?? 0) } }
            .sorted { $0.value > $1.value }
            .map { ($0.key, $0.value) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("At a glance").font(.subheadline.bold()).foregroundStyle(.secondary)
            // Tiles wrap to the available width rather than living in a column.
            FlowLayout(spacing: 10) {
                KPITile(icon: "building.2.fill", tint: .blue,
                        value: "\(store.doc.orgs.count)", label: "Organisations")
                KPITile(icon: "chart.line.uptrend.xyaxis", tint: .green,
                        value: "\(openOpps)", label: "Open opportunities")
                KPITile(icon: "flask.fill", tint: .cyan,
                        value: "\(activePOCs)", label: "Active POCs")
                if activePOCs > 0 {
                    KPITile(icon: "checkmark.seal.fill", tint: .teal,
                            value: "\(Int(pocPassRate * 100))%", label: "POC criteria passed")
                }
                ForEach(pipeline, id: \.0) { cur, cents in
                    KPITile(icon: "dollarsign.circle.fill", tint: .indigo,
                            value: Self.money(cents, cur), label: "Open pipeline (\(cur))")
                }
                KPITile(icon: "doc.text.fill", tint: .gray,
                        value: "\(store.doc.notes.count)", label: "Linked notes")
            }
        }
    }

    static func money(_ cents: Int, _ currency: String) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currency
        f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: Double(cents) / 100)) ?? "\(cents / 100)"
    }
}

private struct KPITile: View {
    let icon: String; let tint: Color; let value: String; let label: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.white).frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 7).fill(tint))
            VStack(alignment: .leading, spacing: 1) {
                Text(value).font(.title3.bold().monospacedDigit())
                Text(label).font(.caption).foregroundColor(.secondary).fixedSize()
            }
        }
        .padding(10)
        .frame(width: 190, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
    }
}

// MARK: Main canvas

/// Time window for the note-scan insights.
enum DashboardRange: String, CaseIterable, Identifiable {
    case day = "Today", week = "7 days", month = "30 days", quarter = "90 days", half = "6 months", all = "All time"
    var id: String { rawValue }
    var days: Int? {
        switch self { case .day: 1; case .week: 7; case .month: 30; case .quarter: 90; case .half: 182; case .all: nil }
    }
}

struct DashboardView: View {
    @ObservedObject var store: CatalogStore
    var openPOCTracker: () -> Void

    @State private var metrics = DashboardMetrics()
    @State private var loading = true
    // Filters
    @State private var range: DashboardRange = .quarter
    @State private var orgFilter = ""          // "" = all accounts
    @State private var pocAtRiskOnly = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                filterBar
                // "At a glance" — instant catalog KPIs as a strip across the top.
                KPIStrip(store: store)
                // Hero — the SE's core artifact, full width.
                pocCard
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 16)],
                          alignment: .leading, spacing: 16) {
                    relationshipsCard
                    activityCard
                    meetingMixCard
                    actionItemsCard
                    competitiveCard
                    coverageCard
                }
            }
            .padding(16)
        }
        .task(id: filterKey) { await load() }
    }

    /// Changing any note-scan filter re-runs the scan (via `.task(id:)`).
    private var filterKey: String { "\(range.rawValue)|\(orgFilter)" }

    /// The selected account plus all descendant orgs (empty when no account filter).
    private var orgSubtreeIDs: Set<String> {
        guard !orgFilter.isEmpty else { return [] }
        var ids: Set<String> = [], queue = [orgFilter]
        while let id = queue.popLast() {
            guard ids.insert(id).inserted else { continue }
            queue.append(contentsOf: store.childOrgs(of: id).map { $0.id })
        }
        return ids
    }
    private var orgSubtreeNames: [String] {
        orgSubtreeIDs.compactMap { store.org($0)?.name }
    }

    private var filterBar: some View {
        HStack(spacing: 12) {
            Picker("Range", selection: $range) {
                ForEach(DashboardRange.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()

            AccountFilterPicker(store: store, selection: $orgFilter)

            Spacer()

            if loading { ProgressView().controlSize(.small) }
            Text("\(metrics.meetingsScanned) meeting\(metrics.meetingsScanned == 1 ? "" : "s")")
                .font(.caption).foregroundColor(.secondary)
            Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                .help("Refresh")
        }
        .padding(.bottom, 2)
    }

    // POC command center. Scoped by the account filter so an SE can focus on one
    // customer's POCs; when a time range is set, limited to POCs with meeting
    // activity in that window (criteria themselves aren't time-stamped).
    private var pocCard: some View {
        var opps = store.doc.opportunities.filter { !$0.pocCriteria.isEmpty }
        if !orgFilter.isEmpty {
            let allowed = Set(store.opportunities(forOrg: orgFilter).map { $0.id })
            opps = opps.filter { allowed.contains($0.id) }
        }
        // Range: keep POCs touched by a meeting in the filtered set ("All time" = no
        // limit). Skip while the scan is in flight so the hero doesn't flash empty.
        if range.days != nil && !loading {
            opps = opps.filter { o in
                store.notes(forOpportunity: o).contains { metrics.scannedURLs.contains(store.url(of: $0)) }
            }
        }
        let all = opps.flatMap { $0.pocCriteria }
        let passed = all.filter { $0.status == .pass }.count
        let failed = all.filter { $0.status == .fail }.count
        let pending = all.filter { $0.status == .pending }.count
        // At-risk: has a failing criterion, or nothing passed yet.
        let atRisk = opps.filter { o in
            o.pocCriteria.contains { $0.status == .fail } ||
            !o.pocCriteria.contains { $0.status == .pass }
        }
        return DashCard(title: "POC Command Center", icon: "flask.fill", tint: .cyan) {
            if all.isEmpty {
                DashEmpty("No POC criteria yet. Add them in the POC Tracker.")
            } else {
                HStack(spacing: 14) {
                    StatNumber("\(passed)", "Passed", .green)
                    StatNumber("\(pending)", "Pending", .secondary)
                    StatNumber("\(failed)", "Failed", .red)
                }
                ProgressView(value: Double(passed), total: Double(max(all.count, 1)))
                    .tint(.green)
                Text("\(passed)/\(all.count) criteria passed across \(opps.count) POC\(opps.count == 1 ? "" : "s")")
                    .font(.caption).foregroundColor(.secondary)
                Divider()
                HStack {
                    Text(pocAtRiskOnly ? "At risk" : "POCs").font(.caption.bold()).foregroundColor(pocAtRiskOnly ? .orange : .secondary)
                    Spacer()
                    Toggle("At-risk only", isOn: $pocAtRiskOnly)
                        .toggleStyle(.checkbox).font(.caption)
                }
                let shown = (pocAtRiskOnly ? atRisk : opps)
                if shown.isEmpty {
                    DashEmpty(pocAtRiskOnly ? "No POCs at risk. 👍" : "No POCs in scope.")
                } else {
                    ForEach(shown.prefix(6), id: \.id) { o in
                        let p = o.pocCriteria.filter { $0.status == .pass }.count
                        let risky = o.pocCriteria.contains { $0.status == .fail } || !o.pocCriteria.contains { $0.status == .pass }
                        HStack {
                            Image(systemName: risky ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                                .foregroundColor(risky ? .orange : .green).font(.caption2)
                            Text(o.name).lineLimit(1)
                            Spacer()
                            Text("\(p)/\(o.pocCriteria.count)").font(.caption.monospacedDigit()).foregroundColor(.secondary)
                        }.font(.callout)
                    }
                }
                Button("Open POC Tracker") { openPOCTracker() }
                    .buttonStyle(.link).font(.caption)
            }
        }
    }

    // MARK: Relationships — who you engage, and who's going quiet.
    // Engagement counts honor the range + account filters (via the scanned set);
    // "going quiet" is recency-based, scoped to the selected account subtree.
    private var relationshipsCard: some View {
        // Restrict to the selected account subtree (or all orgs).
        let orgsInScope = orgFilter.isEmpty
            ? store.doc.orgs
            : store.doc.orgs.filter { orgSubtreeIDs.contains($0.id) }
        let scoped = Set(orgSubtreeNames)
        let stale = DigestService.staleRelationships(asOf: Date())
            .filter { orgFilter.isEmpty || scoped.contains($0.name) }
        let topOrgs = orgsInScope
            .map { org -> (name: String, count: Int) in
                let urls = Set(store.notes(forOrg: org.id, includingDescendants: true).map { store.url(of: $0) })
                return (org.name, urls.intersection(metrics.scannedURLs).count)
            }
            .filter { $0.count > 0 }
            .sorted { $0.count > $1.count }
            .prefix(5)
        return DashCard(title: "Relationships", icon: "person.2.fill", tint: .teal) {
            if loading { DashLoading() }
            else if topOrgs.isEmpty && stale.isEmpty {
                DashEmpty("No linked meetings in this range. Link meetings to organisations and opportunities to see relationship activity here.")
            } else {
                if !topOrgs.isEmpty {
                    Text("Most-engaged accounts").font(.caption.bold()).foregroundColor(.secondary)
                    ForEach(Array(topOrgs), id: \.name) { o in
                        HStack {
                            Text(o.name).lineLimit(1)
                            Spacer()
                            Text("\(o.count) mtg\(o.count == 1 ? "" : "s")")
                                .font(.caption.monospacedDigit()).foregroundColor(.secondary)
                        }.font(.callout)
                    }
                }
                if !stale.isEmpty {
                    Divider()
                    Label("Going quiet", systemImage: "moon.zzz.fill").font(.caption.bold()).foregroundColor(.indigo)
                    ForEach(stale.prefix(5)) { r in
                        HStack {
                            Text(r.name).lineLimit(1)
                            Spacer()
                            Text(r.lastContact).font(.caption).foregroundColor(.secondary)
                        }.font(.callout)
                    }
                }
            }
        }
    }

    // MARK: Activity — cadence and volume (honors the range + account filters).
    private var activityCard: some View {
        DashCard(title: "Activity", icon: "calendar", tint: .purple) {
            if loading { DashLoading() } else {
                HStack(spacing: 14) {
                    StatNumber("\(metrics.meetingsScanned)", "Meetings", .purple)
                    StatNumber(UsageStats.hoursMinutes(metrics.recordedSeconds), "Recorded", .secondary)
                }
                Text("Meetings — last 6 weeks").font(.caption).foregroundColor(.secondary)
                Chart(metrics.weekTrend) { b in
                    BarMark(x: .value("Week", b.label), y: .value("Meetings", b.count))
                        .foregroundStyle(.purple.gradient)
                }
                .frame(height: 110)
            }
        }
    }

    // MARK: Action items — technical commitments.
    private var actionItemsCard: some View {
        DashCard(title: "Action Items", icon: "checklist", tint: .blue) {
            if loading { DashLoading() } else {
                HStack(spacing: 14) {
                    StatNumber("\(metrics.openActions)", "Open", .blue)
                    StatNumber("\(metrics.overdueActions)", "Overdue", metrics.overdueActions > 0 ? .red : .secondary)
                }
                Text("Commitments across \(metrics.meetingsScanned) recent meetings. Tick them off in a note or the Digest.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
    }

    // MARK: Competitive & product intelligence — radar rollup.
    private var competitiveCard: some View {
        DashCard(title: "Competitive & Product Intelligence", icon: "dot.radiowaves.left.and.right", tint: .pink) {
            if loading { DashLoading() }
            else if metrics.radarTop.isEmpty {
                DashEmpty("No watchlist hits. Add competitors, products, or risk phrases under Settings → Recording → Keyword Radar.")
            } else {
                Text("Watchlist mentions across recent meetings").font(.caption).foregroundColor(.secondary)
                Chart(metrics.radarTop) { item in
                    BarMark(x: .value("Mentions", item.count), y: .value("Term", item.label))
                        .foregroundStyle(.pink.gradient)
                        .annotation(position: .trailing) { Text("\(item.count)").font(.caption2).foregroundColor(.secondary) }
                }
                .chartXAxis(.hidden)
                .frame(height: CGFloat(metrics.radarTop.count) * 26 + 10)
            }
        }
    }

    // MARK: Meeting-type mix — where engagements sit in the technical cycle.
    private var meetingMixCard: some View {
        let funnelTotal = metrics.funnel.reduce(0) { $0 + $1.count }
        // Non-cycle meeting types (standups, 1:1s, general, custom…) for context.
        let cycleLabels = Set(DashboardMetrics.funnelOrder)
        let other = metrics.typeMix.filter { !cycleLabels.contains($0.label) }
        return DashCard(title: "Meeting-Type Mix", icon: "chart.bar.xaxis", tint: .indigo) {
            if loading { DashLoading() }
            else if metrics.typeMix.isEmpty {
                DashEmpty("No meeting types recorded in this range. Pick a template when you start a meeting.")
            } else {
                Text("Technical cycle").font(.caption.bold()).foregroundColor(.secondary)
                if funnelTotal == 0 {
                    DashEmpty("No Discovery / Demo / Scoping / Kickoff meetings in this range.")
                } else {
                    Chart(metrics.funnel) { s in
                        BarMark(x: .value("Meetings", s.count), y: .value("Stage", s.label))
                            .foregroundStyle(.indigo.gradient)
                            .annotation(position: .trailing) {
                                Text("\(s.count)").font(.caption2).foregroundColor(.secondary)
                            }
                    }
                    .chartYAxis { AxisMarks(preset: .aligned) }
                    .chartXAxis(.hidden)
                    .chartYScale(domain: DashboardMetrics.funnelOrder.reversed())
                    .frame(height: CGFloat(DashboardMetrics.funnelOrder.count) * 28 + 10)
                }
                if !other.isEmpty {
                    Divider()
                    Text("Other meetings").font(.caption.bold()).foregroundColor(.secondary)
                    ForEach(other.prefix(4)) { t in
                        HStack {
                            Text(t.label).font(.callout).lineLimit(1)
                            Spacer()
                            Text("\(t.count)").font(.caption.monospacedDigit()).foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: Open technical questions — the SE's follow-up queue.
    private var coverageCard: some View {
        DashCard(title: "Open Technical Questions", icon: "questionmark.circle.fill", tint: .orange) {
            if loading { DashLoading() } else {
                if metrics.unanswered.isEmpty {
                    DashEmpty("No unanswered questions in recent meetings.")
                } else {
                    Text("\(metrics.unanswered.count) unresolved — your follow-up queue.")
                        .font(.caption).foregroundColor(.secondary)
                    ForEach(metrics.unanswered.prefix(5)) { q in
                        Button { NotesViewerWindowController.present(fileURL: q.url) } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(q.question).lineLimit(2).font(.callout)
                                Text(q.title).font(.caption2).foregroundColor(.secondary).lineLimit(1)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func load() async {
        loading = true
        let depth = AppSettings.shared.searchDepth
        let wl = AppSettings.shared.watchlist()
        let typeNames = Dictionary(
            AppSettings.shared.allTemplates.map { ($0.id, $0.displayName) },
            uniquingKeysWith: { a, _ in a })
        // Count in whole calendar days: "Today" = today only, "7 days" = today + prior 6.
        let since = range.days.flatMap { Calendar.current.date(byAdding: .day, value: -($0 - 1), to: Date()) }
        // Resolve the account scope to a set of note file URLs (nil = all).
        let allowed: Set<URL>? = orgFilter.isEmpty ? nil
            : Set(store.notes(forOrg: orgFilter, includingDescendants: true).map { store.url(of: $0) })
        let m = await Task.detached(priority: .userInitiated) {
            DashboardMetrics.scan(limit: depth, watchlist: wl, typeNames: typeNames,
                                  since: since, allowed: allowed)
        }.value
        metrics = m
        loading = false
    }
}

// MARK: Account filter — searchable dropdown

/// A compact dropdown for the dashboard's account scope with a search field,
/// so it stays usable as the org list grows (a plain Picker can't search).
private struct AccountFilterPicker: View {
    @ObservedObject var store: CatalogStore
    @Binding var selection: String       // "" = all accounts
    @State private var open = false
    @State private var query = ""

    private var currentName: String {
        selection.isEmpty ? "All accounts" : (store.org(selection)?.name ?? "All accounts")
    }

    /// Orgs in hierarchical order (parent then its children, depth-first) with a
    /// depth for indentation. While searching, flattens to matches (depth 0) so
    /// the query still finds nested accounts.
    private var rows: [(org: CatalogOrg, depth: Int)] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            return store.orgsSorted
                .filter { $0.name.lowercased().contains(q) }
                .map { ($0, 0) }
        }
        var out: [(CatalogOrg, Int)] = []
        func walk(_ org: CatalogOrg, _ depth: Int) {
            out.append((org, depth))
            for child in store.childOrgs(of: org.id) { walk(child, depth + 1) }
        }
        for root in store.rootOrgs { walk(root, 0) }
        return out
    }

    var body: some View {
        Button {
            open = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "building.2").font(.caption)
                Text(currentName).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: 200, alignment: .leading)
        }
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(spacing: 6) {
                TextField("Search accounts", text: $query)
                    .textFieldStyle(.roundedBorder)
                List {
                    accountRow(name: "All accounts", selected: selection.isEmpty, depth: 0) {
                        selection = ""; open = false; query = ""
                    }
                    ForEach(rows, id: \.org.id) { row in
                        accountRow(name: row.org.name, selected: selection == row.org.id, depth: row.depth) {
                            selection = row.org.id; open = false; query = ""
                        }
                    }
                }
                .listStyle(.plain)
            }
            .padding(10)
            .frame(width: 260, height: 320)
        }
    }

    private func accountRow(name: String, selected: Bool, depth: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if depth > 0 {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                Text(name).lineLimit(1)
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
            .padding(.leading, CGFloat(depth) * 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: Card chrome

private struct DashCard<Content: View>: View {
    let title: String; let icon: String; let tint: Color
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.subheadline.bold())
                .foregroundStyle(tint)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.12)))
    }
}

private struct StatNumber: View {
    let value: String; let label: String; let tint: Color
    init(_ v: String, _ l: String, _ t: Color) { value = v; label = l; tint = t }
    var body: some View {
        VStack(spacing: 1) {
            Text(value).font(.title2.bold().monospacedDigit()).foregroundStyle(tint)
            Text(label).font(.caption2).foregroundColor(.secondary)
        }
    }
}

private struct DashEmpty: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View { Text(text).font(.callout).foregroundColor(.secondary) }
}

private struct DashLoading: View {
    var body: some View {
        HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Scanning…").font(.caption).foregroundColor(.secondary) }
    }
}
