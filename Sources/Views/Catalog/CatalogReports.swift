import SwiftUI
import AppKit
import Charts
import UniformTypeIdentifiers

// Catalog › Reports — an industrial-standard reporting surface. Composes the
// same offline insights the Dashboard shows (structural catalog facts +
// note-scan activity + keyword radar) into a professional, selectable report
// with tables AND charts.
//
// The report is modelled as an ordered list of `ReportContent` blocks — the one
// source of truth rendered three ways: on-screen preview and PDF (native
// SwiftUI + Swift Charts, so tables and bar charts render properly), and a
// Markdown string for the .md file and clipboard.

/// One selectable insight block in a report.
enum ReportBlock: String, CaseIterable, Identifiable {
    case overview      = "Overview KPIs"
    case pipeline      = "Pipeline"
    case poc           = "POC status"
    case activity      = "Activity"
    case relationships = "Relationships"
    case meetingMix    = "Meeting-type mix"
    case actions       = "Action items"
    case questions     = "Open technical questions"
    case keywords      = "Keyword intelligence"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .overview:      "chart.bar.fill"
        case .pipeline:      "dollarsign.circle"
        case .poc:           "flask"
        case .activity:      "waveform.path.ecg"
        case .relationships: "person.2"
        case .meetingMix:    "chart.pie"
        case .actions:       "checklist"
        case .questions:     "questionmark.circle"
        case .keywords:      "dot.radiowaves.left.and.right"
        }
    }
    var color: Color {
        switch self {
        case .overview:      .blue
        case .pipeline:      .green
        case .poc:           .cyan
        case .activity:      .orange
        case .relationships: .teal
        case .meetingMix:    .purple
        case .actions:       .pink
        case .questions:     .mint
        case .keywords:      .red
        }
    }
}

/// Cohesive categorical palette for report charts/tiles.
enum ReportPalette {
    static let colors: [Color] = [.blue, .teal, .indigo, .purple, .pink, .orange, .green, .cyan]
    static func color(_ i: Int) -> Color { colors[i % colors.count] }
}

/// A labelled value for a bar chart, with an optional per-bar tint.
struct ReportBar: Identifiable { let id = UUID(); let label: String; let value: Double; var tint: Color? = nil }

/// A rendered report element. Native views draw it; a Markdown fold exports it.
enum ReportContent {
    case heading(String, icon: String, tint: Color)
    case subhead(String)
    case note(String)
    case bullets([String])
    case kpis([(String, String)])
    case table(headers: [String], rows: [[String]])
    case bars(title: String, bars: [ReportBar], horizontal: Bool, unit: String)
}

/// Cached scan results a report is built from (kept off the render path).
private struct ReportData {
    let metrics: DashboardMetrics
    let radar: [RadarTermStat]
    let stale: [DigestService.StaleRelationship]
    let engaged: [(name: String, count: Int)]
}

struct ReportsView: View {
    @ObservedObject var store: CatalogStore

    @State private var title = "Catalog Report"
    @State private var scopeKind = ""        // "", "org", "project"
    @State private var scopeID = ""
    @State private var range: DateRange = .month
    @State private var selected: Set<ReportBlock> = Set(ReportBlock.allCases)
    @State private var data: ReportData?
    @State private var generating = false
    @State private var status = ""

    private var scanKey: String { "\(scopeKind)|\(scopeID)|\(range.rawValue)" }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            HStack(alignment: .top, spacing: 0) {
                blockPicker.frame(width: 220)
                Divider()
                preview.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: scanKey) { await recompute() }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "chart.bar.doc.horizontal").foregroundStyle(.green)
                TextField("Report title", text: $title)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                if generating { ProgressView().controlSize(.small) }
                Spacer()
                Button { copyMarkdown() } label: { Label("Copy", systemImage: "doc.on.doc") }
                Button { saveMarkdown() } label: { Label("Markdown", systemImage: "square.and.arrow.down") }
                Button { exportPDF() } label: { Label("Export PDF", systemImage: "arrow.down.doc") }
                    .buttonStyle(.borderedProminent)
            }
            HStack(spacing: 8) {
                OrgProjectTreePicker(store: store, kind: $scopeKind, id: $scopeID,
                                     allLabel: "All accounts & projects")
                RangePicker(range: $range, compact: true)
                Spacer()
                if !status.isEmpty {
                    Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(12)
    }

    // MARK: Block picker

    private var blockPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Include").font(.headline)
                Spacer()
                Button("All") { selected = Set(ReportBlock.allCases) }.buttonStyle(.borderless).font(.caption)
                Button("None") { selected = [] }.buttonStyle(.borderless).font(.caption)
            }
            ForEach(ReportBlock.allCases) { b in
                Toggle(isOn: binding(b)) { Label(b.rawValue, systemImage: b.icon).font(.callout) }
                    .toggleStyle(.checkbox)
            }
            Spacer()
        }
        .padding(12)
    }

    private func binding(_ b: ReportBlock) -> Binding<Bool> {
        Binding(get: { selected.contains(b) },
                set: { if $0 { selected.insert(b) } else { selected.remove(b) } })
    }

    // MARK: Preview

    private var preview: some View {
        ScrollView {
            if selected.isEmpty {
                ContentUnavailableView("Nothing selected", systemImage: "chart.bar.doc.horizontal",
                    description: Text("Tick the insight blocks to include on the left."))
                    .padding(.top, 60)
            } else {
                ReportRenderView(title: title, subtitle: subtitleText, content: content)
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    // MARK: Scan

    private func recompute() async {
        generating = true
        defer { generating = false }
        let depth = AppSettings.shared.searchDepth
        let wl = AppSettings.shared.watchlist()
        let types = Dictionary(AppSettings.shared.allTemplates.map { ($0.id, $0.displayName) },
                               uniquingKeysWith: { a, _ in a })
        let since = range.days.flatMap { Calendar.current.date(byAdding: .day, value: -($0 - 1), to: Date()) }
        let allowed = allowedURLs()
        let m = await Task.detached(priority: .userInitiated) {
            DashboardMetrics.scan(limit: depth, watchlist: wl, typeNames: types, since: since, allowed: allowed)
        }.value
        let r = await Task.detached(priority: .userInitiated) {
            RadarInsights.aggregate(watchlist: wl, limit: depth)
        }.value
        let scanned = m.scannedURLs
        let engaged = scopedOrgs.map { o -> (name: String, count: Int) in
            let c = store.notes(forOrg: o.id, includingDescendants: true)
                .filter { scanned.contains(store.url(of: $0)) }.count
            return (o.name, c)
        }.filter { $0.count > 0 }.sorted { $0.count > $1.count }
        data = ReportData(metrics: m, radar: r.stats,
                          stale: DigestService.staleRelationships(asOf: Date()), engaged: engaged)
    }

    // MARK: Scope helpers

    private var scopedProjects: [CatalogProject] {
        let all = store.doc.projects.filter { !$0.archived }
        switch scopeKind {
        case "org":
            let s = store.orgSubtree(of: scopeID)
            return all.filter { store.org(forProject: $0.id).map { s.contains($0.id) } ?? false }
        case "project":
            let s = store.projectSubtree(of: scopeID)
            return all.filter { s.contains($0.id) }
        default: return all
        }
    }
    private var scopedOrgs: [CatalogOrg] {
        switch scopeKind {
        case "org":
            let s = store.orgSubtree(of: scopeID)
            return store.doc.orgs.filter { s.contains($0.id) }
        case "project":
            let ids = Set(scopedProjects.compactMap { store.org(forProject: $0.id)?.id })
            return store.doc.orgs.filter { ids.contains($0.id) }
        default: return store.doc.orgs
        }
    }
    private var scopeLabel: String {
        switch scopeKind {
        case "org": return store.org(scopeID)?.name ?? "Account"
        case "project": return store.project(scopeID)?.name ?? "Project"
        default: return "All accounts"
        }
    }
    private var subtitleText: String { "\(scopeLabel) · \(range.rawValue)" }

    private func allowedURLs() -> Set<URL>? {
        switch scopeKind {
        case "org": return Set(store.notes(forOrg: scopeID, includingDescendants: true).map { store.url(of: $0) })
        case "project": return Set(store.notes(forProject: scopeID).map { store.url(of: $0) })
        default: return nil
        }
    }
    private func scopedNoteURLs() -> Set<URL> {
        let notes: [CatalogNote]
        switch scopeKind {
        case "org": notes = store.notes(forOrg: scopeID, includingDescendants: true)
        case "project": notes = store.notes(forProject: scopeID)
        default: notes = store.doc.notes.filter { !store.isUnassigned($0) }
        }
        return Set(notes.map { store.url(of: $0) })
    }

    // MARK: Content assembly (single source of truth)

    private var content: [ReportContent] {
        var out: [ReportContent] = []
        for b in ReportBlock.allCases where selected.contains(b) { out += block(b) }
        return out
    }

    private func head(_ b: ReportBlock, _ title: String) -> ReportContent {
        .heading(title, icon: b.icon, tint: b.color)
    }

    private func block(_ b: ReportBlock) -> [ReportContent] {
        switch b {
        case .overview:      return overview()
        case .pipeline:      return pipeline()
        case .poc:           return poc()
        case .activity:      return activity()
        case .relationships: return relationships()
        case .meetingMix:    return meetingMix()
        case .actions:       return actions()
        case .questions:     return questions()
        case .keywords:      return keywords()
        }
    }

    private func overview() -> [ReportContent] {
        let projects = scopedProjects
        let open = projects.filter { $0.stage == .open }.count
        let pocs = projects.reduce(0) { $0 + $1.pocs.count }
        let crit = projects.flatMap { $0.pocs.flatMap(\.leaves) }
        let passed = crit.filter { $0.status == .pass }.count
        let rate = crit.isEmpty ? 0 : Int(Double(passed) / Double(crit.count) * 100)
        let pipe = pipelineTotals(projects)
        var kpis: [(String, String)] = [
            ("Accounts", "\(scopedOrgs.count)"),
            ("Projects", "\(projects.count) (\(open) open)"),
            ("Active POCs", "\(pocs)"),
            ("POC pass-rate", "\(rate)%"),
            ("Open pipeline", pipe.isEmpty ? "—" : pipe),
            ("Linked notes", "\(scopedNoteURLs().count)"),
        ]
        if let m = data?.metrics { kpis.append(("Meetings in range", "\(m.meetingsScanned)")) }
        return [head(.overview, "Overview"), .kpis(kpis)]
    }

    private func pipeline() -> [ReportContent] {
        let open = scopedProjects.filter { $0.stage == .open }
        var out: [ReportContent] = [head(.pipeline, "Pipeline")]
        let totals = pipelineTotals(scopedProjects)
        out.append(.note("Open pipeline: \(totals.isEmpty ? "—" : totals)"))
        guard !open.isEmpty else { out.append(.note("No open projects in scope.")); return out }
        // Bar: open value by account (major currency units).
        var byAcct: [String: Double] = [:]
        for p in open where p.valueCents != nil {
            let a = store.org(forProject: p.id)?.name ?? "No account"
            byAcct[a, default: 0] += Double(p.valueCents!) / 100
        }
        let bars = byAcct.sorted { $0.value > $1.value }.prefix(8).enumerated()
            .map { ReportBar(label: $1.key, value: $1.value, tint: ReportPalette.color($0)) }
        if !bars.isEmpty { out.append(.bars(title: "Open value by account", bars: Array(bars), horizontal: true, unit: "")) }
        let rows = open.sorted { ($0.valueCents ?? 0) > ($1.valueCents ?? 0) }.prefix(50).map { p in
            [store.org(forProject: p.id)?.name ?? "—", p.name, p.stage.label,
             p.valueCents.map { money($0, p.currency) } ?? "—"]
        }
        out.append(.table(headers: ["Account", "Project", "Stage", "Value"], rows: Array(rows)))
        return out
    }

    private func poc() -> [ReportContent] {
        let pocs = scopedProjects.flatMap { p in p.pocs.map { (p, $0) } }
        var out: [ReportContent] = [head(.poc, "POC Status")]
        guard !pocs.isEmpty else { out.append(.note("No POCs in scope.")); return out }
        var byPhase: [PocPhase: Int] = [:]
        for (_, poc) in pocs { byPhase[poc.phase, default: 0] += 1 }
        let atRisk = pocs.filter { $0.1.isAtRisk }.count
        let bars = PocPhase.allCases.sorted { $0.order < $1.order }
            .compactMap { ph -> ReportBar? in (byPhase[ph] ?? 0) > 0 ? ReportBar(label: ph.label, value: Double(byPhase[ph]!), tint: ph.tint) : nil }
        out.append(.note("\(pocs.count) POC\(pocs.count == 1 ? "" : "s") · at risk: \(atRisk)"))
        if !bars.isEmpty { out.append(.bars(title: "POCs by phase", bars: bars, horizontal: false, unit: "")) }
        let rows = pocs.prefix(80).map { (p, poc) in
            [store.org(forProject: p.id)?.name ?? "—", poc.name, poc.phase.label,
             poc.total == 0 ? "—" : "\(poc.passed)/\(poc.total)\(poc.failed > 0 ? " (\(poc.failed)✗)" : "")",
             poc.deadline.map { deadlineText($0) } ?? "—"]
        }
        out.append(.table(headers: ["Account", "POC", "Phase", "Criteria", "Deadline"], rows: Array(rows)))
        return out
    }

    private func activity() -> [ReportContent] {
        var out: [ReportContent] = [head(.activity, "Activity")]
        guard let m = data?.metrics else { return out + [.note("Scanning…")] }
        out.append(.kpis([("Meetings", "\(m.meetingsScanned)"), ("Recorded", UsageStats.hoursMinutes(m.recordedSeconds))]))
        if !m.weekTrend.isEmpty {
            out.append(.bars(title: "Meetings per week",
                             bars: m.weekTrend.map { ReportBar(label: $0.label, value: Double($0.count), tint: .orange) },
                             horizontal: false, unit: ""))
        }
        return out
    }

    private func relationships() -> [ReportContent] {
        var out: [ReportContent] = [head(.relationships, "Relationships")]
        guard let d = data else { return out + [.note("Scanning…")] }
        out.append(.subhead("Most engaged"))
        if d.engaged.isEmpty { out.append(.note("No meeting activity in range.")) }
        else {
            out.append(.bars(title: "", bars: d.engaged.prefix(8).enumerated().map {
                ReportBar(label: $1.name, value: Double($1.count), tint: ReportPalette.color($0)) },
                             horizontal: true, unit: ""))
        }
        out.append(.subhead("Going quiet"))
        if d.stale.isEmpty { out.append(.note("None flagged.")) }
        else { out.append(.bullets(d.stale.prefix(8).map { "\($0.name) — last contact \($0.lastContact)" })) }
        return out
    }

    private func meetingMix() -> [ReportContent] {
        var out: [ReportContent] = [head(.meetingMix, "Meeting-Type Mix")]
        guard let m = data?.metrics else { return out + [.note("Scanning…")] }
        let funnel = m.funnel.filter { $0.count > 0 }
        if !funnel.isEmpty {
            out.append(.bars(title: "Technical-cycle funnel", bars: funnel.enumerated().map {
                ReportBar(label: $1.label, value: Double($1.count), tint: ReportPalette.color($0 + 2)) },
                             horizontal: false, unit: ""))
        }
        let others = m.typeMix.filter { !DashboardMetrics.funnelOrder.contains($0.label) && $0.count > 0 }
        if !others.isEmpty {
            out.append(.subhead("Other meetings"))
            out.append(.bullets(others.prefix(10).map { "\($0.label): \($0.count)" }))
        }
        return out
    }

    private func actions() -> [ReportContent] {
        var out: [ReportContent] = [head(.actions, "Action Items")]
        guard let m = data?.metrics else { return out + [.note("Scanning…")] }
        out.append(.kpis([("Open", "\(m.openActions)"), ("Overdue", "\(m.overdueActions)")]))
        return out
    }

    private func questions() -> [ReportContent] {
        var out: [ReportContent] = [head(.questions, "Open Technical Questions")]
        guard let m = data?.metrics else { return out + [.note("Scanning…")] }
        guard !m.unanswered.isEmpty else { return out + [.note("None outstanding.")] }
        out.append(.bullets(m.unanswered.prefix(40).map { "\($0.question) — \($0.title)" }))
        return out
    }

    private func keywords() -> [ReportContent] {
        var out: [ReportContent] = [head(.keywords, "Keyword Intelligence")]
        guard let stats = data?.radar, !stats.isEmpty else {
            return out + [.note("No watchlist mentions (set keywords in Keyword Radar / Settings).")]
        }
        out.append(.bars(title: "Top mentions", bars: stats.prefix(10).enumerated().map {
            ReportBar(label: $1.term, value: Double($1.total), tint: ReportPalette.color($0)) },
                         horizontal: true, unit: ""))
        let rows = stats.prefix(15).map { [$0.term, "\($0.total)", "\($0.meetings)", $0.lastDay] }
        out.append(.table(headers: ["Term", "Mentions", "Meetings", "Last seen"], rows: Array(rows)))
        return out
    }

    // MARK: Formatting helpers

    private func pipelineTotals(_ projects: [CatalogProject]) -> String {
        let open = projects.filter { $0.stage == .open && $0.valueCents != nil }
        let byCurrency = Dictionary(grouping: open, by: { $0.currency })
            .mapValues { $0.reduce(0) { $0 + ($1.valueCents ?? 0) } }
        return byCurrency.keys.sorted().map { money(byCurrency[$0]!, $0) }.joined(separator: "; ")
    }
    private func money(_ cents: Int, _ currency: String) -> String {
        let f = NumberFormatter(); f.numberStyle = .currency; f.currencyCode = currency; f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: Double(cents) / 100)) ?? "\(cents / 100) \(currency)"
    }
    private func deadlineText(_ d: Date) -> String {
        let base = d.formatted(date: .abbreviated, time: .omitted)
        if let st = DeadlineState(d), st.isUrgent { return "\(base) · \(st.label)" }
        return base
    }

    private var markdown: String { ReportMarkdown.build(title: title, subtitle: subtitleText, content) }
    private var fileBase: String {
        let t = title.trimmingCharacters(in: .whitespaces)
        return (t.isEmpty ? "Report" : t).replacingOccurrences(of: "/", with: "-")
    }

    // MARK: Export

    /// Render the native report view (tables + charts) to an image, then tile it
    /// across US-Letter pages using `NSImage.draw(in:from:)`, which always draws
    /// upright regardless of the PDF context's coordinate system — so the output
    /// can't come out mirrored or upside-down.
    private func exportPDF() {
        let view = ReportRenderView(title: title, subtitle: subtitleText, content: content)
        let sz = AppSettings.shared.pdfPageSize
        guard let pdf = ViewPDF.data(blocks: view.blocks, pageW: sz.width, pageH: sz.height) else {
            status = "Couldn't render PDF."; return
        }
        if let s = FilePanels.save(defaultName: fileBase + ".pdf", contentTypes: [.pdf],
                                   successVerb: "Exported", failVerb: "Export",
                                   write: { try pdf.write(to: $0) }) {
            status = s
        }
    }

    private func saveMarkdown() {
        if let s = FilePanels.save(defaultName: fileBase + ".md",
                                   contentTypes: [UTType(filenameExtension: "md") ?? .plainText],
                                   write: { try markdown.write(to: $0, atomically: true, encoding: .utf8) }) {
            status = s
        }
    }

    private func copyMarkdown() {
        Clipboard.markdown(markdown)
        status = "Copied report to clipboard."
    }
}

// MARK: - Native renderer (preview + PDF)

private struct ReportRenderView: View {
    let title: String
    let subtitle: String
    let content: [ReportContent]

    private var headerTint: Color { .green }

    // Gradient title banner, shared by the on-screen preview and the PDF blocks.
    private var banner: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.largeTitle.bold()).foregroundStyle(.white)
            Text(subtitle).font(.subheadline).foregroundStyle(.white.opacity(0.9))
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [headerTint, .teal, .blue],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            banner
            ForEach(Array(content.enumerated()), id: \.offset) { _, c in element(c) }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    /// One block per element (plus the banner) for the block-based PDF pager,
    /// so a chart/table/card is never split across a page. A heading is paired
    /// with the element that follows it so it can't be orphaned at a page foot.
    var blocks: [AnyView] {
        var out: [AnyView] = [AnyView(banner)]
        var i = 0
        while i < content.count {
            if case .heading = content[i], i + 1 < content.count {
                let h = content[i], next = content[i + 1]
                out.append(AnyView(VStack(alignment: .leading, spacing: 10) { element(h); element(next) }))
                i += 2
            } else {
                out.append(AnyView(element(content[i])))
                i += 1
            }
        }
        return out
    }

    @ViewBuilder private func element(_ c: ReportContent) -> some View {
        switch c {
        case .heading(let s, let icon, let tint):
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 7).fill(tint.gradient))
                Text(s).font(.title2.bold())
            }
            .padding(.top, 12)
            RoundedRectangle(cornerRadius: 1).fill(tint.opacity(0.5)).frame(height: 2)
        case .subhead(let s): Text(s).font(.headline).padding(.top, 4)
        case .note(let s): Text(s).font(.callout).foregroundStyle(.secondary)
        case .bullets(let xs):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(xs.indices, id: \.self) { i in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "circle.fill").font(.system(size: 5)).foregroundStyle(.tertiary).padding(.top, 6)
                        Text(xs[i]).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        case .kpis(let items): kpiGrid(items)
        case .table(let h, let rows): tableView(h, rows)
        case .bars(let t, let bars, let horizontal, _): barChart(t, bars, horizontal)
        }
    }

    private func kpiGrid(_ items: [(String, String)]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 10)], alignment: .leading, spacing: 10) {
            ForEach(items.indices, id: \.self) { i in
                let tint = ReportPalette.color(i)
                HStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: 2).fill(tint).frame(width: 4)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(items[i].1).font(.title3.bold().monospacedDigit()).foregroundStyle(tint)
                        Text(items[i].0).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .padding(10)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 9).fill(tint.opacity(0.10)))
            }
        }
    }

    private func tableView(_ headers: [String], _ rows: [[String]]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
            GridRow {
                ForEach(headers.indices, id: \.self) { c in
                    Text(headers[c].uppercased()).font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                        .kerning(0.4).gridColumnAlignment(.leading)
                }
            }
            Divider()
            ForEach(rows.indices, id: \.self) { r in
                GridRow {
                    ForEach(rows[r].indices, id: \.self) { c in
                        Text(rows[r][c]).font(.caption)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if r < rows.count - 1 { Divider().opacity(0.4) }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.gray.opacity(0.15)))
    }

    @ViewBuilder private func barChart(_ title: String, _ bars: [ReportBar], _ horizontal: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !title.isEmpty { Text(title).font(.subheadline.weight(.semibold)) }
            Chart(bars) { bar in
                if horizontal {
                    BarMark(x: .value("Value", bar.value), y: .value("Label", bar.label))
                        .foregroundStyle((bar.tint ?? .accentColor).gradient)
                        .cornerRadius(4)
                        .annotation(position: .trailing) {
                            Text("\(Int(bar.value))").font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                        }
                } else {
                    BarMark(x: .value("Label", bar.label), y: .value("Value", bar.value))
                        .foregroundStyle((bar.tint ?? .accentColor).gradient)
                        .cornerRadius(4)
                }
            }
            .chartXAxis { if horizontal { AxisMarks() } else { AxisMarks(preset: .aligned) } }
            .frame(height: horizontal ? max(90, CGFloat(bars.count) * 28 + 20) : 180)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.gray.opacity(0.15)))
    }
}

// MARK: - Markdown fold (for .md file + clipboard)

enum ReportMarkdown {
    static func build(title: String, subtitle: String, _ content: [ReportContent]) -> String {
        var s = "# \(title)\n_\(subtitle)_\n\n"
        for c in content {
            switch c {
            case .heading(let h, _, _): s += "## \(h)\n\n"
            case .subhead(let t): s += "**\(t)**\n\n"
            case .note(let t): s += "\(t)\n\n"
            case .bullets(let xs): for x in xs { s += "- \(esc(x))\n" }; s += "\n"
            case .kpis(let items):
                s += "| Metric | Value |\n| --- | --- |\n"
                for (k, v) in items { s += "| \(esc(k)) | \(esc(v)) |\n" }; s += "\n"
            case .table(let h, let rows):
                s += "| " + h.map(esc).joined(separator: " | ") + " |\n"
                s += "| " + h.map { _ in "---" }.joined(separator: " | ") + " |\n"
                for r in rows { s += "| " + r.map(esc).joined(separator: " | ") + " |\n" }
                s += "\n"
            case .bars(let t, let bars, _, _):
                if !t.isEmpty { s += "**\(t)**\n\n" }
                s += "| Item | Value |\n| --- | --- |\n"
                for b in bars { s += "| \(esc(b.label)) | \(num(b.value)) |\n" }; s += "\n"
            }
        }
        return s
    }
    private static func esc(_ s: String) -> String { s.replacingOccurrences(of: "|", with: "\\|") }
    private static func num(_ v: Double) -> String { v.rounded() == v ? String(Int(v)) : String(format: "%.1f", v) }
}
