import SwiftUI
import Charts

// MARK: - Keyword Radar Insights (Catalog section)
//
// Cross-meeting view of the Keyword Radar, living inside the Catalog (sidebar →
// Tools → Keyword Radar) alongside the POC Tracker and Dashboard — all
// note-analytics in one place. The per-meeting scan already mirrors watchlist
// hits into each note's Mentions section and tags; this aggregates those hits
// across the archive — which terms come up, how often, in how many meetings,
// and when last — with drill-down to the source meetings. Read-only and
// offline: it re-scans note bodies against the current watchlist, so terms
// added later surface retroactively.

// MARK: Aggregation

struct RadarTermStat: Identifiable {
    let term: String
    let total: Int       // total mentions across all scanned meetings
    let meetings: Int    // how many distinct meetings mentioned it
    let lastDay: String  // "yyyy-MM-dd" of the most recent mention
    var id: String { term }
}

struct RadarHit: Identifiable {
    let id = UUID()
    let file: NotesLibrary.MeetingFile
    let title: String
    let day: String
    let count: Int
}

enum RadarInsights {
    struct Result {
        var stats: [RadarTermStat] = []
        var hitsByTerm: [String: [RadarHit]] = [:]
        var scanned: Int = 0
    }

    /// Scan up to `limit` recent meetings for the watchlist terms. Pure/offline;
    /// safe to run off the main thread.
    static func aggregate(watchlist: [String], limit: Int) -> Result {
        guard !watchlist.isEmpty else { return Result() }
        var totals: [String: Int] = [:]
        var meetings: [String: Int] = [:]
        var lastDay: [String: String] = [:]
        var hitsByTerm: [String: [RadarHit]] = [:]
        let files = NotesLibrary.meetingFiles(limit: limit)   // newest-first

        for f in files {
            guard let text = f.url.readText() else { continue }
            let body = FrontMatter.body(text)
            let title = FrontMatter.title(in: text) ?? f.displayName
            let counts = MeetingNotesWriter.mentionCounts(in: body, terms: watchlist)
            for c in counts where c.count > 0 {
                totals[c.term, default: 0] += c.count
                meetings[c.term, default: 0] += 1
                if lastDay[c.term] == nil { lastDay[c.term] = f.day }   // newest-first → first is latest
                hitsByTerm[c.term, default: []].append(
                    RadarHit(file: f, title: title, day: f.day, count: c.count))
            }
        }

        let stats = watchlist.compactMap { term -> RadarTermStat? in
            let t = totals[term] ?? 0
            guard t > 0 else { return nil }
            return RadarTermStat(term: term, total: t,
                                 meetings: meetings[term] ?? 0,
                                 lastDay: lastDay[term] ?? "")
        }.sorted { $0.total > $1.total }

        return Result(stats: stats, hitsByTerm: hitsByTerm, scanned: files.count)
    }
}

/// Shared loaded state so the Catalog's content (term list) and detail
/// (meetings for a term) columns run a single scan between them.
@MainActor
final class RadarModel: ObservableObject {
    @Published var result = RadarInsights.Result()
    @Published var loading = true
    @Published var loaded = false

    func loadIfNeeded() async {
        guard !loaded else { return }
        loading = true
        let terms = AppSettings.shared.watchlist()
        let depth = AppSettings.shared.searchDepth
        let r = await Task.detached(priority: .userInitiated) {
            RadarInsights.aggregate(watchlist: terms, limit: depth)
        }.value
        result = r
        loading = false
        loaded = true
    }

    func reload() async { loaded = false; await loadIfNeeded() }
}

// MARK: Content column — term list

private enum RadarSort: String, CaseIterable, Identifiable {
    case mentions = "Mentions", meetings = "Meetings", recent = "Recent", name = "Name"
    var id: String { rawValue }
}
private enum RadarGroup: String, CaseIterable, Identifiable {
    case none = "None", date = "Last mention"
    var id: String { rawValue }
}

struct RadarTermList: View {
    @ObservedObject var store: CatalogStore
    @ObservedObject var model: RadarModel
    @Binding var selID: String?

    @State private var query = ""
    @State private var sort: RadarSort = .mentions
    @State private var grouping: RadarGroup = .none
    @State private var range: DateRange = .all
    @State private var scopeKind = ""   // "", "org", "project"
    @State private var scopeID = ""
    @State private var newTerm = ""
    @State private var expanded: Set<String> = []
    @State private var seeded = false

    private var watchlist: [String] { AppSettings.shared.watchlist() }

    private var activeFilters: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty || range != .all
            || !scopeID.isEmpty || grouping != .none || sort != .mentions
    }

    // MARK: Derived

    private func lastDate(_ s: RadarTermStat) -> Date? { DateDisplay.posixDay.date(from: s.lastDay) }

    /// Note keyed by file path, for mapping a hit back to its catalog note (and
    /// thus its account/project) when an org/project scope is active.
    private var noteByPath: [String: CatalogNote] {
        Dictionary(store.doc.notes.map { (store.url(of: $0).path, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private func scopeAllows(_ url: URL) -> Bool {
        guard !scopeID.isEmpty else { return true }
        guard let note = noteByPath[url.path] else { return false }
        if scopeKind == "org" {
            let sub = store.orgSubtree(of: scopeID)
            return store.effectiveOrgIDs(of: note).contains { sub.contains($0) }
        }
        if scopeKind == "project" {
            let sub = store.projectSubtree(of: scopeID)
            return store.effectiveProjectIDs(of: note).contains { sub.contains($0) }
        }
        return true
    }

    /// Term stats, recomputed from the scoped hits when an account/project filter
    /// is active (so totals/meetings reflect just that scope).
    private var scopedStats: [RadarTermStat] {
        guard !scopeID.isEmpty else { return model.result.stats }
        return model.result.stats.compactMap { stat in
            let hits = (model.result.hitsByTerm[stat.term] ?? []).filter { scopeAllows($0.file.url) }
            guard !hits.isEmpty else { return nil }
            return RadarTermStat(term: stat.term,
                                 total: hits.reduce(0) { $0 + $1.count },
                                 meetings: hits.count,
                                 lastDay: hits.map(\.day).max() ?? "")
        }
    }

    private var rows: [RadarTermStat] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return scopedStats
            .filter { q.isEmpty || $0.term.lowercased().contains(q) }
            .filter { range.days == nil || range.includes(lastDate($0)) }
            .sorted { a, b in
                switch sort {
                case .mentions: return a.total != b.total ? a.total > b.total : a.term < b.term
                case .meetings: return a.meetings != b.meetings ? a.meetings > b.meetings : a.term < b.term
                case .recent:   return a.lastDay != b.lastDay ? a.lastDay > b.lastDay : a.term < b.term
                case .name:     return a.term.localizedCaseInsensitiveCompare(b.term) == .orderedAscending
                }
            }
    }
    private var maxTotal: Int { rows.map(\.total).max() ?? 1 }
    private var tree: [DateGroupNode<RadarTermStat>] { DateGrouping.tree(rows) { lastDate($0) } }
    private var allGroupKeys: Set<String> { DateGrouping.allKeys(tree) }

    private func reset() {
        query = ""; sort = .mentions; grouping = .none; range = .all
        scopeKind = ""; scopeID = ""
    }

    private func addTerm() {
        let t = newTerm.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        AppSettings.shared.addWatchlistTerms(t)
        newTerm = ""
        Task { await model.reload() }   // rescan so the new term's hits appear
    }

    var body: some View {
        VStack(spacing: 0) {
            addBar
            Divider()
            if model.loading {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Scanning meetings…").font(.caption).foregroundColor(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if watchlist.isEmpty {
                empty("No watchlist terms yet",
                      "Add competitors, product names, or risk phrases with the field above — every finished meeting is scanned locally for them.")
            } else if model.result.stats.isEmpty {
                empty("No mentions found",
                      "None of your \(watchlist.count) watchlist term\(watchlist.count == 1 ? "" : "s") appeared in the last \(model.result.scanned) meeting\(model.result.scanned == 1 ? "" : "s").")
            } else {
                statsStrip
                controls
                Divider()
                if rows.isEmpty {
                    empty("No terms match", "Adjust the search, scope, or range to see more.")
                } else {
                    list
                }
            }
        }
        .task { await model.loadIfNeeded() }
        .onChange(of: grouping) { _, _ in expanded = allGroupKeys }
        .onChange(of: tree.map(\.id)) { _, _ in if !seeded { expanded = allGroupKeys; seeded = true } }
        .toolbar {
            ToolbarItem {
                Button { Task { await model.reload() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Rescan meetings")
            }
        }
    }

    // MARK: Add-keyword bar

    private var addBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(.red)
            TextField("Add a watchlist term — competitor, product, risk phrase…", text: $newTerm)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .onSubmit(addTerm)
            Button {
                addTerm()
            } label: {
                Label("Add", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
    }

    // MARK: Stats strip

    private var statsStrip: some View {
        let totalMentions = rows.reduce(0) { $0 + $1.total }
        return HStack(spacing: 8) {
            pill("\(rows.count)", "terms", .red, "dot.radiowaves.left.and.right")
            pill("\(totalMentions)", "mentions", .accentColor, "sum")
            pill("\(model.result.scanned)", "scanned", .secondary, "doc.text.magnifyingglass")
            Spacer()
        }
        .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 6)
    }

    private func pill(_ value: String, _ label: String, _ tint: Color, _ icon: String) -> some View {
        StatPill(icon: icon, value: value, label: label, tint: tint)
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                EntitySearchBar(text: $query, placeholder: "Search terms…")
                OrgProjectTreePicker(store: store, kind: $scopeKind, id: $scopeID,
                                     allLabel: "All accounts & projects")
            }
            HStack(spacing: 6) {
                menu("Group", grouping.rawValue) {
                    Picker("", selection: $grouping) { ForEach(RadarGroup.allCases) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.inline).labelsHidden()
                }
                menu("Sort", sort.rawValue) {
                    Picker("", selection: $sort) { ForEach(RadarSort.allCases) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.inline).labelsHidden()
                }
                RangePicker(range: $range, compact: true)
                Spacer(minLength: 0)
                if grouping == .date {
                    Button {
                        expanded = expanded.isSuperset(of: allGroupKeys) && !allGroupKeys.isEmpty ? [] : allGroupKeys
                    } label: {
                        Image(systemName: expanded.isSuperset(of: allGroupKeys) && !allGroupKeys.isEmpty
                              ? "chevron.up.circle" : "chevron.down.circle")
                    }
                    .buttonStyle(.borderless).help("Expand or collapse all groups")
                }
                if activeFilters {
                    ResetButton(help: "Reset search, scope, sort, group & range", action: reset)
                }
            }
        }
        .padding(.horizontal, 10).padding(.bottom, 8)
    }

    private func menu<Content: View>(_ title: String, _ value: String,
                                     @ViewBuilder content: () -> Content) -> some View {
        Menu { content() } label: {
            HStack(spacing: 3) {
                Text(title).foregroundStyle(.secondary)
                Text(value).fontWeight(.medium)
            }.font(.caption)
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    // MARK: List

    @ViewBuilder private var list: some View {
        List(selection: $selID) {
            if grouping == .date {
                DateGroupDisclosure(nodes: tree, expanded: $expanded) { stat in
                    RadarTermRow(stat: stat, maxTotal: maxTotal).tag(stat.term)
                }
            } else {
                ForEach(rows) { stat in
                    RadarTermRow(stat: stat, maxTotal: maxTotal).tag(stat.term)
                }
            }
        }
    }

    private func empty(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.largeTitle).foregroundColor(.secondary)
            Text(title).font(.headline)
            Text(detail).font(.caption).foregroundColor(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 320)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding()
    }
}

// MARK: Detail column — meetings for the selected term

struct RadarTermDetail: View {
    @ObservedObject var store: CatalogStore
    @ObservedObject var model: RadarModel
    let term: String?
    /// Drill-down: when set, the meetings list is scoped to this account's key.
    @State private var selectedAccount: String? = nil

    /// Which accounts/projects mention the term, tallied from the hit files'
    /// catalog notes — answers "who's talking about <competitor>".
    private struct AccountMention: Identifiable {
        let id: String
        let name: String
        let isOrg: Bool
        var meetings: Int
        var mentions: Int
    }

    private var noteByPath: [String: CatalogNote] {
        Dictionary(store.doc.notes.map { (store.url(of: $0).path, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// The account/project a single hit belongs to — shared by the tally and the
    /// meeting drill-down so they always agree.
    private func accountInfo(_ hit: RadarHit) -> (key: String, name: String, isOrg: Bool) {
        let note = noteByPath[hit.file.url.path]
        if let pid = note?.projectIDs.first, store.project(pid) != nil {
            return ("p:" + pid, store.projectPath(of: pid), false)
        }
        if let oid = note?.orgIDs.first ?? note.flatMap({ store.effectiveOrgIDs(of: $0).first }),
           store.org(oid) != nil {
            return ("o:" + oid, store.orgPath(of: oid), true)
        }
        return ("unassigned", "Unassigned", false)
    }

    private func accountMentions(_ hits: [RadarHit]) -> [AccountMention] {
        var order: [String] = []
        var byKey: [String: AccountMention] = [:]
        for hit in hits {
            let info = accountInfo(hit)
            if byKey[info.key] == nil {
                byKey[info.key] = AccountMention(id: info.key, name: info.name, isOrg: info.isOrg, meetings: 0, mentions: 0)
                order.append(info.key)
            }
            byKey[info.key]?.meetings += 1
            byKey[info.key]?.mentions += hit.count
        }
        return order.compactMap { byKey[$0] }.sorted { $0.mentions > $1.mentions }
    }

    private func tint(_ a: AccountMention) -> Color {
        a.id == "unassigned" ? .secondary : (a.isOrg ? .blue : .orange)
    }

    /// Horizontal bar chart of the top accounts by mentions — the visual "who's
    /// talking about this term" insight. Tapping a bar filters the meetings.
    @ViewBuilder private func mentionsChart(_ accounts: [AccountMention]) -> some View {
        let top = Array(accounts.prefix(8))
        Chart(top) { a in
            BarMark(x: .value("Mentions", a.mentions), y: .value("Account", a.name))
                .foregroundStyle(tint(a))
                .opacity(selectedAccount == nil || selectedAccount == a.id ? 1 : 0.3)
                .annotation(position: .trailing, alignment: .leading) {
                    Text("\(a.mentions)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
        }
        .chartXAxis(.hidden)
        .frame(height: max(70, CGFloat(top.count) * 30))
        .padding(.vertical, 4)
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onTapGesture { loc in
                        guard let plot = proxy.plotFrame else { return }
                        let y = loc.y - geo[plot].origin.y
                        if let name = proxy.value(atY: y, as: String.self),
                           let a = top.first(where: { $0.name == name }) {
                            selectedAccount = (selectedAccount == a.id) ? nil : a.id
                        }
                    }
            }
        }
    }

    var body: some View {
        if let term, let hits = model.result.hitsByTerm[term], !hits.isEmpty {
            let accounts = accountMentions(hits)
            let multiAccount = accounts.count > 1 || (accounts.first.map { $0.id != "unassigned" } ?? false)
            let scoped = selectedAccount == nil ? hits : hits.filter { accountInfo($0).key == selectedAccount }
            let selName = accounts.first { $0.id == selectedAccount }?.name
            List {
                Section {
                    HStack(spacing: 8) {
                        summaryStat("\(hits.reduce(0) { $0 + $1.count })", "mentions")
                        summaryStat("\(hits.count)", "meetings")
                        if multiAccount { summaryStat("\(accounts.count)", "accounts") }
                        Spacer()
                    }
                } header: { Text("“\(term)”").font(.headline).textCase(nil) }

                if multiAccount {
                    Section {
                        mentionsChart(accounts)
                    } header: {
                        Text("Who mentions it")
                    } footer: {
                        Text("Tap a bar to show only that account's meetings.")
                    }
                }

                Section {
                    ForEach(scoped) { hit in
                        Button { NotesViewerWindowController.present(fileURL: hit.file.url) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(hit.title).lineLimit(1)
                                    Text(DateDisplay.day(hit.day)).font(.caption).foregroundColor(.secondary)
                                }
                                Spacer()
                                Text("×\(hit.count)").font(.caption.monospacedDigit()).foregroundColor(.secondary)
                            }
                        }.buttonStyle(.plain)
                    }
                } header: {
                    HStack {
                        Text(selName.map { "\($0) · \(scoped.count) mtg\(scoped.count == 1 ? "" : "s")" }
                             ?? "Meetings · \(scoped.count)")
                            .lineLimit(1)
                        if selectedAccount != nil {
                            Spacer()
                            Button("Show all") { selectedAccount = nil }
                                .font(.caption).buttonStyle(.borderless)
                        }
                    }
                }
            }
            .frame(minWidth: 300)
            .onChange(of: term) { _, _ in selectedAccount = nil }
        } else {
            ContentUnavailableView("Keyword Radar", systemImage: "dot.radiowaves.left.and.right",
                                   description: Text("Select a term to see who mentions it and the source meetings."))
        }
    }

    private func summaryStat(_ value: String, _ label: String) -> some View {
        HStack(spacing: 3) {
            Text(value).font(.title3.weight(.semibold).monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// One term row: name, a proportional bar, and total / meeting counts.
private struct RadarTermRow: View {
    let stat: RadarTermStat
    let maxTotal: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(stat.term).fontWeight(.medium).lineLimit(1)
                Spacer()
                Text("\(stat.total)").font(.callout.monospacedDigit().bold())
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15))
                    Capsule().fill(Color.accentColor.opacity(0.7))
                        .frame(width: geo.size.width * barFraction)
                }
            }
            .frame(height: 4)
            Text("\(stat.meetings) meeting\(stat.meetings == 1 ? "" : "s")\(stat.lastDay.isEmpty ? "" : " · last \(DateDisplay.day(stat.lastDay))")")
                .font(.caption2).foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var barFraction: CGFloat {
        guard maxTotal > 0 else { return 0 }
        return max(0.04, CGFloat(stat.total) / CGFloat(maxTotal))
    }
}
