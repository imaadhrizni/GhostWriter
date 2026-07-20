import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Catalog · POC tracker

enum PocState: String, CaseIterable, Identifiable {
    case atRisk = "At risk", inProgress = "In progress", complete = "Complete",
         notStarted = "Not started", noCriteria = "No criteria"
    var id: String { rawValue }

    /// Classify from criteria tallies.
    static func of(total: Int, passed: Int, failed: Int) -> PocState {
        if total == 0 { return .noCriteria }
        if failed > 0 { return .atRisk }
        if passed == total { return .complete }
        if passed == 0 { return .notStarted }
        return .inProgress
    }

    var icon: String {
        switch self {
        case .atRisk: "exclamationmark.triangle.fill"
        case .inProgress: "circle.lefthalf.filled"
        case .complete: "checkmark.seal.fill"
        case .notStarted: "circle"
        case .noCriteria: "questionmark.circle"
        }
    }
    var color: Color {
        switch self {
        case .atRisk: .red; case .inProgress: .accentColor; case .complete: .green
        case .notStarted: .orange; case .noCriteria: .secondary
        }
    }
    /// Sort weight so at-risk work floats up and finished/empty work sinks.
    var priority: Int {
        switch self {
        case .atRisk: 0; case .inProgress: 1; case .notStarted: 2; case .complete: 3; case .noCriteria: 4
        }
    }
}

/// Small colored capsule showing a POC's lifecycle phase.
struct PhasePill: View {
    let phase: PocPhase
    var body: some View {
        HStack(spacing: 3) {
            Circle().fill(phase.tint).frame(width: 6, height: 6)
            Text(phase.label).font(.caption2.weight(.medium))
        }
        .foregroundStyle(phase.tint)
        .pillBackground(phase.tint, opacity: 0.12, hPad: 6, vPad: 2)
    }
}

enum PocSort: String, CaseIterable, Identifiable {
    case priority = "At-risk first", deadline = "Deadline", name = "Name", progress = "Progress", recent = "Recent activity"
    var id: String { rawValue }
}
enum PocGroup: String, CaseIterable, Identifiable {
    case phase = "Phase", health = "Health", account = "Account", project = "Project", date = "Date", none = "None"
    var id: String { rawValue }
}
/// The Status filter: the Open (planned/in-progress/on-hold) / Closed
/// (passed/failed) / All lifecycle scopes, plus a specific phase. Defaults to
/// Open in the tracker.
enum PocStatusSel: Hashable, Identifiable {
    case open, closed, all, phase(PocPhase)
    static var allCases: [PocStatusSel] { [.open, .closed, .all] + PocPhase.allCases.map { .phase($0) } }
    var id: String { label }
    var label: String {
        switch self {
        case .open: "Open"; case .closed: "Closed"; case .all: "All"; case .phase(let p): p.label
        }
    }
    func includes(_ p: PocPhase) -> Bool {
        switch self {
        case .open: p.isOpen; case .closed: !p.isOpen; case .all: true; case .phase(let ph): p == ph
        }
    }
    var isDefault: Bool { if case .open = self { return true } else { return false } }
}

/// A POC plus its owning project and computed tallies — the unit the tracker
/// filters, sorts, and groups. A single project may contribute several rows.
struct PocRow: Identifiable {
    let project: CatalogProject
    let poc: Poc
    var id: String { poc.id }
    let accountPath: String
    let lastActivity: Date?

    var total: Int  { poc.total }
    var passed: Int { poc.passed }
    var failed: Int { poc.failed }
    var pending: Int { total - passed - failed }
    var state: PocState { .of(total: total, passed: passed, failed: failed) }
    var progress: Double { total == 0 ? 0 : Double(passed) / Double(total) }
    var deadline: Date? { poc.deadline }
}

/// The POC Tracker master list — every POC across all projects, filterable by
/// account/project/phase/health, groupable, and sortable, with a per-row
/// deadline pill and a drill-down to the owning project's linked meetings.
struct PocProjectList: View {
    @ObservedObject var store: CatalogStore
    @Binding var selID: String?        // selected POC id

    @State private var query = ""
    @State private var statusSel: PocStatusSel = .open       // default: open POCs only
    @State private var healthFilter: PocState? = nil
    @State private var scopeKind = ""                    // "", "org", "project"
    @State private var scopeID = ""
    @State private var range: DateRange = .all           // by last activity OR deadline
    @State private var sort: PocSort = .priority
    @State private var grouping: PocGroup = .account
    @State private var expanded: Set<String> = []          // open group keys
    @State private var expandedProjects: Set<String> = []  // POC rows showing linked notes
    @State private var seeded = false
    @State private var showNewPoc = false

    // MARK: Derived data

    private func accountLabel(_ p: CatalogProject) -> String {
        var parts: [String] = []
        if let org = store.org(forProject: p.id) { parts.append(store.orgPath(of: org.id)) }
        parts.append(contentsOf: store.projectLineage(of: p.id).dropFirst().reversed()
            .compactMap { store.project($0)?.name })
        return parts.isEmpty ? "—" : parts.joined(separator: " › ")
    }

    private func row(project p: CatalogProject, poc: Poc) -> PocRow {
        PocRow(project: p, poc: poc,
               accountPath: accountLabel(p),
               lastActivity: store.notes(forProject: p.id).compactMap(\.date).max())
    }

    private var allRows: [PocRow] {
        store.doc.projects.filter { !$0.archived }.flatMap { p in p.pocs.map { row(project: p, poc: $0) } }
    }

    private var filtered: [PocRow] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let orgScope = scopeKind == "org" ? store.orgSubtree(of: scopeID) : nil
        let projScope = scopeKind == "project" ? store.projectSubtree(of: scopeID) : nil
        return allRows.filter { r in
            (q.isEmpty || r.poc.name.lowercased().contains(q)
                       || r.project.name.lowercased().contains(q)
                       || r.accountPath.lowercased().contains(q))
            && statusSel.includes(r.poc.phase)
            && (healthFilter == nil || r.state == healthFilter)
            && (orgScope == nil || (store.org(forProject: r.project.id).map { orgScope!.contains($0.id) } ?? false))
            && (projScope == nil || projScope!.contains(r.project.id))
            // A ranged view keeps POCs with activity OR a deadline in the window,
            // so a deadline-only POC is never hidden by the time filter.
            && (range.days == nil || range.includes(r.lastActivity) || range.includes(r.deadline))
        }
    }

    private var sorted: [PocRow] {
        filtered.sorted { a, b in
            switch sort {
            case .priority:
                if a.state.priority != b.state.priority { return a.state.priority < b.state.priority }
                return a.progress > b.progress
            case .deadline:
                return (a.deadline ?? .distantFuture) < (b.deadline ?? .distantFuture)
            case .name:     return a.poc.name.localizedCaseInsensitiveCompare(b.poc.name) == .orderedAscending
            case .progress: return a.progress > b.progress
            case .recent:   return (a.lastActivity ?? .distantPast) > (b.lastActivity ?? .distantPast)
            }
        }
    }

    /// The date tree (Year→Month→Day by last meeting activity) for date grouping.
    private var dateTree: [DateGroupNode<PocRow>] {
        DateGrouping.tree(sorted) { $0.lastActivity }
    }

    /// The owning project's linked meeting notes, newest-first.
    private func linkedNotes(_ p: CatalogProject) -> [CatalogNote] {
        store.notes(forProject: p.id).sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    /// (key, title, tint, rows) buckets for the current grouping, ordered.
    private var groups: [(key: String, title: String, tint: Color, rows: [PocRow])] {
        switch grouping {
        case .none, .date:
            return [("all", "All POCs", .cyan, sorted)]
        case .phase:
            return PocPhase.allCases.sorted { $0.order < $1.order }.compactMap { ph in
                let rows = sorted.filter { $0.poc.phase == ph }
                return rows.isEmpty ? nil : (ph.rawValue, ph.label, ph.tint, rows)
            }
        case .health:
            return PocState.allCases.compactMap { st in
                let rows = sorted.filter { $0.state == st }
                return rows.isEmpty ? nil : (st.rawValue, st.rawValue, st.color, rows)
            }
        case .project:
            var order: [String] = []; var byKey: [String: [PocRow]] = [:]
            for r in sorted {
                if byKey[r.project.id] == nil { order.append(r.project.id) }
                byKey[r.project.id, default: []].append(r)
            }
            return order.map { ($0, byKey[$0]!.first!.project.name, .cyan, byKey[$0]!) }
        case .account:
            var order: [String] = []; var byKey: [String: [PocRow]] = [:]
            for r in sorted {
                let key = store.org(forProject: r.project.id)?.name ?? "No account"
                if byKey[key] == nil { order.append(key) }
                byKey[key, default: []].append(r)
            }
            return order.sorted { $0 == "No account" ? false : ($1 == "No account" ? true : $0 < $1) }
                .map { ($0, $0, .cyan, byKey[$0]!) }
        }
    }

    // MARK: Overall stats

    private var stats: (pocs: Int, atRisk: Int, complete: Int, dueSoon: Int, passed: Int, criteria: Int) {
        let rows = allRows
        return (rows.count,
                rows.filter { $0.total > 0 && $0.state == .atRisk }.count,
                rows.filter { $0.total > 0 && $0.state == .complete }.count,
                rows.filter { DeadlineState($0.deadline)?.isUrgent == true }.count,
                rows.reduce(0) { $0 + $1.passed },
                rows.reduce(0) { $0 + $1.total })
    }

    private var activeFilters: Bool {
        !statusSel.isDefault || healthFilter != nil || !scopeID.isEmpty
        || range != .all || !query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: Body

    var body: some View {
        Group {
            if store.doc.projects.isEmpty {
                ContentUnavailableView("No projects", systemImage: "flask",
                    description: Text("Add a project under Records, then track its POCs here."))
            } else {
                VStack(spacing: 0) {
                    statsStrip
                    controls
                    Divider()
                    if allRows.isEmpty {
                        ContentUnavailableView("No POCs yet", systemImage: "flask",
                            description: Text("Tap ＋ to create a POC and start tracking its criteria and timeline."))
                    } else if sorted.isEmpty {
                        ContentUnavailableView("No POCs match", systemImage: "line.3.horizontal.decrease.circle",
                            description: Text("Adjust the filters or range to see more."))
                    } else {
                        list
                    }
                }
            }
        }
        .onAppear { if !seeded { expanded = allGroupKeys; seeded = true } }
        .onChange(of: grouping) { _, _ in expanded = allGroupKeys }
        .sheet(isPresented: $showNewPoc) {
            NewPocSheet(store: store, presetProjID: scopeKind == "project" ? scopeID : nil) { newID in
                selID = newID
            }
        }
    }

    private var allGroupKeys: Set<String> {
        grouping == .date ? DateGrouping.allKeys(dateTree) : Set(groups.map(\.key))
    }

    // MARK: Stats strip

    private var statsStrip: some View {
        let s = stats
        let pct = s.criteria == 0 ? 0 : Double(s.passed) / Double(s.criteria)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                statPill("\(s.pocs)", "POCs", .cyan, "flask")
                statPill("\(s.atRisk)", "at risk", .red, "exclamationmark.triangle.fill")
                statPill("\(s.complete)", "complete", .green, "checkmark.seal.fill")
                if s.dueSoon > 0 { statPill("\(s.dueSoon)", "due soon", .orange, "calendar.badge.exclamationmark") }
                Spacer()
            }
            if s.criteria > 0 {
                HStack(spacing: 6) {
                    ProgressView(value: pct).tint(pct == 1 ? .green : .accentColor)
                    Text("\(s.passed)/\(s.criteria)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)
    }

    private func statPill(_ value: String, _ label: String, _ tint: Color, _ icon: String) -> some View {
        StatPill(icon: icon, value: value, label: label, tint: tint)
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                EntitySearchBar(text: $query, placeholder: "Search POCs…")
                OrgProjectTreePicker(store: store, kind: $scopeKind, id: $scopeID,
                                     allLabel: "All accounts & projects")
                filterMenu
                exportMenu
                Button { showNewPoc = true } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless).help("New POC")
            }
            HStack(spacing: 6) {
                menu("Status", statusSel.label) {
                    Picker("", selection: $statusSel) { ForEach(PocStatusSel.allCases) { Text($0.label).tag($0) } }
                        .pickerStyle(.inline).labelsHidden()
                }
                menu("Group", grouping.rawValue) {
                    Picker("", selection: $grouping) { ForEach(PocGroup.allCases) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.inline).labelsHidden()
                }
                menu("Sort", sort.rawValue) {
                    Picker("", selection: $sort) { ForEach(PocSort.allCases) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.inline).labelsHidden()
                }
                RangePicker(range: $range, compact: true)
                Spacer(minLength: 0)
                if grouping != .none {
                    Button {
                        let all = allGroupKeys
                        expanded = expanded.isSuperset(of: all) && !all.isEmpty ? [] : all
                    } label: {
                        Image(systemName: expanded.isSuperset(of: allGroupKeys) && !allGroupKeys.isEmpty
                              ? "chevron.up.circle" : "chevron.down.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Expand or collapse all groups")
                }
                if anyNonDefault {
                    ResetButton(help: "Reset search, filters, group, sort & range", action: reset)
                }
            }
        }
        .padding(.horizontal, 10).padding(.bottom, 8)
    }

    /// True when any control is off its default (drives the Reset button).
    private var anyNonDefault: Bool {
        activeFilters || grouping != .account || sort != .priority
    }
    private func reset() {
        query = ""; statusSel = .open; healthFilter = nil; scopeKind = ""; scopeID = ""
        range = .all; grouping = .account; sort = .priority
    }

    /// Health lives under this badged Filter menu (Status has its own labeled
    /// dropdown in the controls row).
    private var filterMenu: some View {
        Menu {
            Picker("Health", selection: $healthFilter) {
                Text("All health").tag(PocState?.none)
                ForEach(PocState.allCases) { Text($0.rawValue).tag(PocState?.some($0)) }
            }
            Divider()
            Button("Reset filters") {
                statusSel = .open; healthFilter = nil; scopeKind = ""; scopeID = ""; range = .all; query = ""
            }
            .disabled(!activeFilters)
        } label: {
            Label("Filter", systemImage: activeFilters
                  ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton).fixedSize()
        .overlay(alignment: .topTrailing) {
            if activeFilters {
                Circle().fill(Color.accentColor).frame(width: 6, height: 6).offset(x: 2, y: -1)
            }
        }
    }

    /// Export / share every POC in the current filtered, sorted view as one
    /// document — copy (rich text), save Markdown, or a paginated PDF.
    private var exportMenu: some View {
        let items = sorted.map { (project: $0.project, poc: $0.poc, accountPath: $0.accountPath) }
        let title = exportTitle
        let doc = PocExport.markdown(items, title: title)
        let base = PocExport.fileBase(title)
        return Menu {
            Button { _ = PocExport.copy(PocExport.titled(doc, title)) } label: {
                Label("Copy \(items.count) POCs", systemImage: "doc.on.doc")
            }
            Divider()
            Button { _ = PocPDF.export(PocDocBuilder.report(items, title: title), base: base) } label: {
                Label("Export PDF…", systemImage: "arrow.down.doc")
            }
            Button { _ = PocExport.saveMarkdown(PocExport.titled(doc, title), base: base) } label: {
                Label("Save Markdown…", systemImage: "text.append")
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
        }
        .menuStyle(.borderlessButton).fixedSize()
        .disabled(sorted.isEmpty)
        .help("Export the POCs shown here (respects the current filters)")
    }

    /// Title for an all-POCs export — names the scoped account/project if one
    /// is picked, else a generic report title.
    private var exportTitle: String {
        if scopeKind == "org", let o = store.org(scopeID) { return "\(o.name) — POC Report" }
        if scopeKind == "project", let p = store.project(scopeID) { return "\(p.name) — POC Report" }
        return "POC Report"
    }

    private func menu<Content: View>(_ title: String, _ value: String,
                                     @ViewBuilder content: () -> Content) -> some View {
        Menu {
            content()
        } label: {
            HStack(spacing: 3) {
                Text(title).foregroundStyle(.secondary)
                Text(value).fontWeight(.medium)
            }
            .font(.caption)
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    // MARK: List

    @ViewBuilder private var list: some View {
        List {
            if grouping == .date {
                DateGroupDisclosure(nodes: dateTree, expanded: $expanded) { pocBlock($0) }
            } else {
                ForEach(groups, id: \.key) { g in
                    if grouping == .none {
                        ForEach(g.rows) { pocBlock($0) }
                    } else {
                        DisclosureGroup(isExpanded: binding(g.key)) {
                            ForEach(g.rows) { pocBlock($0) }
                        } label: {
                            HStack(spacing: 6) {
                                Circle().fill(g.tint).frame(width: 7, height: 7)
                                Text(g.title).font(.subheadline.weight(.semibold))
                                Spacer()
                                Text("\(g.rows.count)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private func binding(_ key: String) -> Binding<Bool> {
        Binding(get: { expanded.contains(key) },
                set: { if $0 { expanded.insert(key) } else { expanded.remove(key) } })
    }

    /// A POC row plus, when expanded, its project's linked meeting notes.
    @ViewBuilder private func pocBlock(_ r: PocRow) -> some View {
        let notes = linkedNotes(r.project)
        VStack(spacing: 0) {
            pocRow(r, noteCount: notes.count)
            if expandedProjects.contains(r.id) {
                ForEach(notes) { noteSubRow($0) }
            }
        }
    }

    private func pocRow(_ r: PocRow, noteCount: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: r.state.icon)
                .foregroundStyle(r.state.color)
                .font(.system(size: 15))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(r.poc.name).lineLimit(1)
                    PhasePill(phase: r.poc.phase)
                }
                Text(r.project.name + " · " + r.accountPath).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                if r.total > 0 {
                    HStack(spacing: 6) {
                        ProgressView(value: r.progress)
                            .tint(r.state.color).frame(width: 60)
                        Text("\(r.passed)/\(r.total)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        if r.failed > 0 {
                            Text("\(r.failed) failed").font(.caption2).foregroundStyle(.red)
                        }
                    }
                }
            }
            Spacer(minLength: 4)
            if let dl = r.deadline { DeadlineBadge(deadline: dl) }
            if let d = r.lastActivity {
                Text(d.formatted(.relative(presentation: .named)))
                    .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
            if noteCount > 0 {
                Button {
                    if expandedProjects.contains(r.id) { expandedProjects.remove(r.id) }
                    else { expandedProjects.insert(r.id) }
                } label: {
                    Image(systemName: expandedProjects.contains(r.id) ? "chevron.down" : "chevron.right")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("\(noteCount) linked note\(noteCount == 1 ? "" : "s")")
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(selID == r.id ? Color.accentColor.opacity(0.14) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { selID = r.id }
    }

    /// One linked meeting note, indented under its POC; opens on click.
    private func noteSubRow(_ n: CatalogNote) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text").font(.caption2).foregroundStyle(.secondary)
            Text(n.title).font(.caption).lineLimit(1)
            if let d = n.date {
                Text(d.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            Image(systemName: "arrow.up.forward.square").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.leading, 34).padding(.trailing, 6).padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { NotesViewerWindowController.present(fileURL: store.url(of: n)) }
    }
}

/// Sheet to create a new POC: pick the owning project, name it, create.
struct NewPocSheet: View {
    @ObservedObject var store: CatalogStore
    let presetProjID: String?
    var onCreate: (String?) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var kind = ""
    @State private var projID = ""
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New POC").font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: 6) {
                Text("Project").font(.caption).foregroundStyle(.secondary)
                OrgProjectTreePicker(store: store, kind: $kind, id: $projID,
                                     allLabel: nil, scope: .projectsOnly, placeholder: "Choose a project…")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Name").font(.caption).foregroundStyle(.secondary)
                TextField("e.g. Security evaluation, Scale test…", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(create)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") { create() }
                    .buttonStyle(.borderedProminent)
                    .disabled(projID.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 380)
        .onAppear { if let p = presetProjID { kind = "project"; projID = p } }
    }

    private func create() {
        guard !projID.isEmpty else { return }
        let id = store.addPoc(name: name, to: projID)
        onCreate(id)
        dismiss()
    }
}

/// Detail pane: one selected POC — its name, phase, timeline, description, and
/// success criteria (add, cycle status, remove, seed from meetings).
/// Sheet for pasting a whole list of criteria at once (indentation → hierarchy).
struct PocBulkAddSheet: View {
    var onAdd: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Bulk add criteria").font(.title3.weight(.semibold))
            Text("One criterion per line. Indent a line (spaces or a tab) to nest it under the one above — to any depth. Bullets like “* ” or “1.” are stripped; commas stay part of the text.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text)
                .font(.body.monospaced())
                .frame(minWidth: 460, minHeight: 220)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            HStack {
                let n = text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
                Text(n == 0 ? " " : "\(n) line\(n == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") { onAdd(text); dismiss() }
                    .buttonStyle(.borderedProminent)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 520)
    }
}

/// One criterion positioned in the display tree (with its indent depth).
struct PocCritNode: Identifiable {
    let criterion: PocCriterion
    let depth: Int
    var id: String { criterion.id }
}

struct PocDetail: View {
    @ObservedObject var store: CatalogStore
    let pocID: String?
    @State private var newCriterion = ""
    @State private var suggesting = false
    @State private var status = ""
    @State private var confirmClear = false
    @State private var confirmDelete = false
    @State private var draftName = ""
    @State private var draftDetail = ""
    @State private var collapsedCrit: Set<String> = []   // collapsed sub-trees
    @State private var addingUnder: String? = nil         // criterion id we're adding a child to
    @State private var childText = ""
    @State private var showBulkAdd = false
    @State private var editingCrit: String? = nil         // criterion id being edited
    @State private var editText = ""
    @State private var expandedDetail: Set<String> = []   // criteria showing their description
    @State private var detailDrafts: [String: String] = [:] // in-flight description edits, by criterion id
    @FocusState private var editFocused: Bool
    @FocusState private var nameFocused: Bool
    @FocusState private var detailFocused: Bool
    @FocusState private var critDetailFocus: String?      // which criterion's description field has focus

    private var found: (project: CatalogProject, poc: Poc)? { pocID.flatMap { store.poc($0) } }

    /// The bridge can run only when cloud AI is available and the project has
    /// at least one linked meeting to read.
    private var canSuggest: Bool {
        guard let f = found else { return false }
        return !AppSettings.shared.localOnlyMode && !store.notes(forProject: f.project.id).isEmpty
    }

    var body: some View {
        if let f = found {
            let opp = f.project, poc = f.poc
            VStack(alignment: .leading, spacing: 14) {
                header(opp, poc)
                descriptionField(opp, poc)
                if poc.criteria.isEmpty {
                    ContentUnavailableView("No success criteria yet", systemImage: "checklist",
                        description: Text("Add the measurable outcomes this POC must prove — or seed them from the project's meetings."))
                        .frame(maxHeight: .infinity)
                } else {
                    criteriaList(opp, poc)
                }
                addBar(opp, poc)
            }
            .padding(18)
            .animation(.default, value: status)
            .onAppear { draftName = poc.name; draftDetail = poc.detail }
            .onChange(of: pocID) { _, _ in
                draftName = poc.name; draftDetail = poc.detail
                editingCrit = nil; addingUnder = nil
            }
            .confirmationDialog("Clear this POC's criteria?",
                                isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear \(poc.criteria.count) criteri\(poc.criteria.count == 1 ? "on" : "a")", role: .destructive) {
                    store.clearPocCriteria(pocID: poc.id, in: opp.id)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Removes every success criterion from “\(poc.name)”. The POC and project stay — you can re-add criteria anytime.")
            }
            .confirmationDialog("Delete this POC?",
                                isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete “\(poc.name)”", role: .destructive) {
                    store.removePoc(poc.id, from: opp.id)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Removes this POC and its criteria from “\(opp.name)”. The project itself stays in the Catalog.")
            }
        } else {
            ContentUnavailableView("Select a POC", systemImage: "flask",
                description: Text("Pick a POC to track its criteria and timeline — or create one with ＋."))
        }
    }

    // MARK: Header

    @ViewBuilder private func header(_ opp: CatalogProject, _ poc: Poc) -> some View {
        let total = poc.total, passed = poc.passed, failed = poc.failed
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "flask").foregroundStyle(.cyan)
                TextField("POC name", text: $draftName)
                    .textFieldStyle(.plain).font(.title3.weight(.semibold))
                    .focused($nameFocused)
                    .onSubmit { commitName(opp, poc) }
                    .onChange(of: nameFocused) { _, f in if !f { commitName(opp, poc) } }
                Spacer()
                Button { suggestFromMeetings(opp, poc) } label: {
                    if suggesting { ProgressView().controlSize(.small) }
                    else { Label("Suggest from meetings", systemImage: "sparkles") }
                }
                .disabled(!canSuggest || suggesting)
                .help(canSuggest
                      ? "Read this project's linked meetings and add the success criteria they mention"
                      : "Needs cloud AI (not Local-only) and at least one meeting linked to this project")
                shareMenu(opp, poc)
            }
            // Owning project / account path.
            Text(accountPath(opp)).font(.caption).foregroundStyle(.secondary)
            // Phase + timeline. Lays out on one row when the pane is wide enough,
            // else stacks so the date fields and deadline pill never get clipped.
            phaseMenu(opp, poc)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) { timelineDates(opp, poc); Spacer(minLength: 0) }
                VStack(alignment: .leading, spacing: 8) { timelineDates(opp, poc) }
            }
            // Destructive actions, kept subtle.
            HStack(spacing: 14) {
                Spacer()
                if total > 0 {
                    Button(role: .destructive) { confirmClear = true } label: {
                        Label("Clear all criteria", systemImage: "eraser")
                    }
                    .buttonStyle(.borderless).font(.caption)
                    .help("Remove all success criteria from this POC (the POC and project stay)")
                }
                Button(role: .destructive) { confirmDelete = true } label: {
                    Label("Delete POC", systemImage: "trash")
                }
                .buttonStyle(.borderless).font(.caption)
                .help("Delete this POC entirely (the project stays)")
            }
            if total > 0 {
                HStack(spacing: 12) {
                    Text("\(passed)/\(total) passed").font(.subheadline.weight(.medium))
                    if failed > 0 { Text("\(failed) failed").font(.subheadline).foregroundStyle(.red) }
                    Spacer()
                    if passed == total {
                        Label("All criteria met", systemImage: "checkmark.seal.fill")
                            .font(.caption).foregroundStyle(.green)
                    }
                }
                ProgressView(value: Double(passed), total: Double(total))
                    .tint(passed == total ? .green : .accentColor)
            }
            if !status.isEmpty {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func accountPath(_ p: CatalogProject) -> String {
        var parts: [String] = []
        if let org = store.org(forProject: p.id) { parts.append(store.orgPath(of: org.id)) }
        parts.append(p.name)
        return parts.joined(separator: " › ")
    }

    /// Export / share this POC: save as Markdown or export a paginated PDF.
    private func shareMenu(_ opp: CatalogProject, _ poc: Poc) -> some View {
        let doc = PocExport.markdown(project: opp, poc: poc, accountPath: accountPath(opp))
        let base = PocExport.fileBase(poc.name)
        return Menu {
            Button {
                status = PocPDF.export(PocDocBuilder.single(project: opp, poc: poc,
                                                             accountPath: accountPath(opp)), base: base)
            } label: {
                Label("Export PDF…", systemImage: "arrow.down.doc")
            }
            Button { status = PocExport.saveMarkdown(PocExport.titled(doc, poc.name), base: base) } label: {
                Label("Save Markdown…", systemImage: "text.append")
            }
        } label: {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help("Copy or export this POC and its criteria")
    }

    private func phaseMenu(_ opp: CatalogProject, _ poc: Poc) -> some View {
        Menu {
            Picker("Phase", selection: Binding(
                get: { poc.phase },
                set: { store.setPocPhase($0, pocID: poc.id, in: opp.id) })) {
                ForEach(PocPhase.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.inline).labelsHidden()
        } label: {
            PhasePill(phase: poc.phase)
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    /// The start + target date controls plus the deadline pill — used in both
    /// the wide (one-row) and narrow (stacked) layouts via `ViewThatFits`.
    @ViewBuilder private func timelineDates(_ opp: CatalogProject, _ poc: Poc) -> some View {
        dateControl("Start", date: poc.startDate, defaultDays: 0) {
            store.setPocStartDate($0, pocID: poc.id, in: opp.id)
        }
        dateControl("Target", date: poc.deadline, defaultDays: 14) {
            store.setPocDeadline($0, pocID: poc.id, in: opp.id)
        }
        if let d = poc.deadline { DeadlineBadge(deadline: d) }
    }

    @ViewBuilder private func dateControl(_ label: String, date: Date?, defaultDays: Int,
                                          set: @escaping (Date?) -> Void) -> some View {
        if let d = date {
            HStack(spacing: 4) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                DatePicker("", selection: Binding(get: { d }, set: { set($0) }),
                           displayedComponents: .date)
                    .labelsHidden().datePickerStyle(.compact)
                Button { set(nil) } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain).help("Clear the \(label.lowercased()) date")
            }
        } else {
            Button {
                set(Calendar.current.date(byAdding: .day, value: defaultDays, to: Date()))
            } label: {
                Label("\(label) date", systemImage: "calendar.badge.plus")
            }
            .buttonStyle(.borderless).font(.caption)
        }
    }

    private func descriptionField(_ opp: CatalogProject, _ poc: Poc) -> some View {
        TextField("What must this POC prove? (optional)", text: $draftDetail, axis: .vertical)
            .textFieldStyle(.roundedBorder)
            .lineLimit(1...3)
            .focused($detailFocused)
            .onChange(of: detailFocused) { _, f in
                if !f { store.setPocDetail(draftDetail, pocID: poc.id, in: opp.id) }
            }
    }

    private func commitName(_ opp: CatalogProject, _ poc: Poc) {
        let clean = draftName.trimmingCharacters(in: .whitespaces)
        if clean.isEmpty { draftName = poc.name } else if clean != poc.name {
            store.renamePoc(poc.id, in: opp.id, to: clean)
        }
    }

    // MARK: Criteria

    // MARK: Criteria tree

    private func children(of parent: String?, in poc: Poc) -> [PocCriterion] {
        poc.criteria.filter { $0.parentID == parent }
    }
    private func hasChildren(_ c: PocCriterion, _ poc: Poc) -> Bool {
        poc.criteria.contains { $0.parentID == c.id }
    }
    /// Passed/total over a parent's descendant leaves (for the roll-up count).
    private func subtreeTally(_ c: PocCriterion, _ poc: Poc) -> (passed: Int, total: Int) {
        var stack = [c.id]; var leaves: [PocCriterion] = []
        while let id = stack.popLast() {
            let kids = poc.criteria.filter { $0.parentID == id }
            if kids.isEmpty {
                if let leaf = poc.criteria.first(where: { $0.id == id }) { leaves.append(leaf) }
            } else {
                stack.append(contentsOf: kids.map(\.id))
            }
        }
        return (leaves.filter { $0.status == .pass }.count, leaves.count)
    }

    /// Flatten the criteria hierarchy into a display order (pre-order DFS),
    /// honoring collapsed sub-trees.
    private func critNodes(_ poc: Poc) -> [PocCritNode] {
        var out: [PocCritNode] = []
        func walk(_ parent: String?, _ depth: Int) {
            for c in children(of: parent, in: poc) {
                out.append(PocCritNode(criterion: c, depth: depth))
                if hasChildren(c, poc) && !collapsedCrit.contains(c.id) { walk(c.id, depth + 1) }
            }
        }
        walk(nil, 0)
        return out
    }

    /// Ids of criteria that have children (the collapsible parents).
    private func parentIDs(_ poc: Poc) -> [String] {
        poc.criteria.filter { c in poc.criteria.contains { $0.parentID == c.id } }.map(\.id)
    }

    private func criteriaList(_ opp: CatalogProject, _ poc: Poc) -> some View {
        let parents = parentIDs(poc)
        let allCollapsed = !parents.isEmpty && parents.allSatisfy { collapsedCrit.contains($0) }
        return VStack(spacing: 0) {
            if !parents.isEmpty {
                HStack {
                    Spacer()
                    Button {
                        if allCollapsed { collapsedCrit.subtract(parents) } else { collapsedCrit.formUnion(parents) }
                    } label: {
                        Image(systemName: allCollapsed ? "chevron.down.circle" : "chevron.up.circle")
                            .font(.system(size: 14)).frame(width: 26, height: 26).contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless).help(allCollapsed ? "Expand all sub-criteria" : "Collapse all sub-criteria")
                }
            }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(critNodes(poc)) { node in
                        criterionRow(opp, poc, node)
                        Divider()
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    /// A comfortably-sized icon button (26×26 hit area) for the criterion rows.
    private func critIcon(_ icon: String, _ help: String, size: CGFloat = 14,
                          color: Color = .secondary, disabled: Bool = false,
                          _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: size)).foregroundStyle(color)
                .frame(width: 26, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.borderless).disabled(disabled).help(help)
    }

    @ViewBuilder private func criterionRow(_ opp: CatalogProject, _ poc: Poc, _ node: PocCritNode) -> some View {
        let c = node.criterion
        let parent = hasChildren(c, poc)
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 6) {
                Color.clear.frame(width: CGFloat(node.depth) * 18, height: 1)
                if parent {
                    critIcon(collapsedCrit.contains(c.id) ? "chevron.right" : "chevron.down",
                             "Collapse or expand sub-criteria") { toggleCollapse(c.id) }
                } else {
                    critIcon(c.status.icon, "Click to cycle: Pending → Passed → Failed",
                             size: 16, color: c.status.color) {
                        store.setPocStatus(c.status.next, criterionID: c.id, pocID: poc.id, projID: opp.id)
                    }
                }
                if editingCrit == c.id {
                    TextField("Criterion", text: $editText, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...6)
                        .focused($editFocused)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onSubmit { commitEdit(opp, poc) }
                        .onChange(of: editFocused) { _, f in if !f { commitEdit(opp, poc) } }
                } else {
                    Text(c.text)
                        .strikethrough(!parent && c.status == .pass, color: .secondary)
                        .foregroundStyle(!parent && c.status == .fail ? Color.red : .primary)
                        .fontWeight(parent ? .medium : .regular)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { beginEdit(c) }
                        .help("Double-click to edit")
                }
                if parent {
                    let t = subtreeTally(c, poc)
                    Text("\(t.passed)/\(t.total)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                } else {
                    Text(c.status.label).font(.caption).foregroundStyle(c.status.color)
                }
                let sibs = children(of: c.parentID, in: poc)
                let idx = sibs.firstIndex { $0.id == c.id } ?? 0
                critIcon("chevron.up", "Move up", disabled: idx == 0) {
                    store.movePocCriterion(c.id, up: true, pocID: poc.id, projID: opp.id)
                }
                critIcon("chevron.down", "Move down", disabled: idx >= sibs.count - 1) {
                    store.movePocCriterion(c.id, up: false, pocID: poc.id, projID: opp.id)
                }
                critIcon(c.detail.isEmpty ? "text.badge.plus" : "text.alignleft",
                         c.detail.isEmpty ? "Add a description" : "Show / edit description",
                         color: c.detail.isEmpty ? .secondary : .accentColor) { toggleDetail(c) }
                critIcon("pencil", "Edit criterion") { beginEdit(c) }
                critIcon("plus.circle", "Add a sub-criterion") { addingUnder = c.id; childText = "" }
                critIcon("xmark.circle", parent ? "Remove this item and its sub-criteria" : "Remove criterion") {
                    store.removePocCriterion(c.id, pocID: poc.id, from: opp.id)
                }
            }
            .padding(.vertical, 4)
            if expandedDetail.contains(c.id) {
                HStack(alignment: .top, spacing: 6) {
                    Color.clear.frame(width: CGFloat(node.depth + 1) * 18, height: 1)
                    Image(systemName: "text.alignleft").font(.caption2).foregroundStyle(.secondary).padding(.top, 5)
                    TextField("Add a description… (optional)", text: detailBinding(c), axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .font(.callout)
                        .lineLimit(1...8)
                        .focused($critDetailFocus, equals: c.id)
                        .onSubmit { commitDetail(opp, poc, c.id) }
                        .onChange(of: critDetailFocus) { old, _ in if old == c.id { commitDetail(opp, poc, c.id) } }
                }
                .padding(.leading, 6)
                .padding(.bottom, 8)
            } else if !c.detail.isEmpty {
                // Collapsed but has detail: show a one-line preview so it's discoverable.
                HStack(alignment: .top, spacing: 6) {
                    Color.clear.frame(width: CGFloat(node.depth + 1) * 18, height: 1)
                    Text(c.detail)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { toggleDetail(c) }
                }
                .padding(.leading, 6)
                .padding(.bottom, 6)
            }
            if addingUnder == c.id {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .top, spacing: 8) {
                        Color.clear.frame(width: CGFloat(node.depth + 1) * 18, height: 1)
                        TextField("Sub-criterion… (one per line to add several)",
                                  text: $childText, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(1...4)
                            .onSubmit { commitChild(opp, poc, parent: c.id) }
                        Button("Add") { commitChild(opp, poc, parent: c.id) }
                            .disabled(childText.trimmingCharacters(in: .whitespaces).isEmpty)
                        Button("Cancel") { addingUnder = nil }
                    }
                    if splitCriteria(childText).count > 1 {
                        Text("Adds \(splitCriteria(childText).count) sub-criteria (indent to nest deeper)")
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(.leading, CGFloat(node.depth + 1) * 18)
                    }
                }
                .padding(.bottom, 8)
            }
        }
    }

    private func beginEdit(_ c: PocCriterion) {
        editText = c.text; editingCrit = c.id; editFocused = true
    }
    private func commitEdit(_ opp: CatalogProject, _ poc: Poc) {
        if let id = editingCrit {
            store.setPocCriterionText(editText, criterionID: id, pocID: poc.id, projID: opp.id)
        }
        editingCrit = nil
    }

    private func toggleCollapse(_ id: String) {
        if collapsedCrit.contains(id) { collapsedCrit.remove(id) } else { collapsedCrit.insert(id) }
    }

    /// Show / hide a criterion's description editor. Seeds the draft on open.
    private func toggleDetail(_ c: PocCriterion) {
        if expandedDetail.contains(c.id) {
            expandedDetail.remove(c.id)
            detailDrafts[c.id] = nil
        } else {
            detailDrafts[c.id] = c.detail
            expandedDetail.insert(c.id)
            critDetailFocus = c.id
        }
    }

    /// Two-way binding to a criterion's in-flight description draft.
    private func detailBinding(_ c: PocCriterion) -> Binding<String> {
        Binding(get: { detailDrafts[c.id] ?? c.detail },
                set: { detailDrafts[c.id] = $0 })
    }

    /// Persist a criterion's edited description to the store.
    private func commitDetail(_ opp: CatalogProject, _ poc: Poc, _ id: String) {
        guard let draft = detailDrafts[id] else { return }
        store.setPocCriterionDetail(draft, criterionID: id, pocID: poc.id, projID: opp.id)
    }

    private func commitChild(_ opp: CatalogProject, _ poc: Poc, parent: String) {
        // Parse one-per-line (indent to nest deeper), all rooted under `parent`.
        let lines = parseBulk(childText)
        guard !lines.isEmpty else { return }
        store.addPocCriteriaTree(lines, under: parent, toPoc: poc.id, in: opp.id)
        childText = ""; addingUnder = nil
        collapsedCrit.remove(parent)   // reveal the newly added children
    }

    private func addBar(_ opp: CatalogProject, _ poc: Poc) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                TextField("Add a success criterion…", text: $newCriterion, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .onSubmit { commitAdd(opp, poc) }
                Button("Add") { commitAdd(opp, poc) }
                    .disabled(newCriterion.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Bulk…") { showBulkAdd = true }
                    .help("Paste a whole list — one criterion per line; indent lines to nest them")
            }
            if splitCriteria(newCriterion).count > 1 {
                Text("Adds \(splitCriteria(newCriterion).count) criteria (one per line)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $showBulkAdd) {
            PocBulkAddSheet { text in
                let lines = parseBulk(text)
                guard !lines.isEmpty else { return }
                store.addPocCriteriaTree(lines, under: nil, toPoc: poc.id, in: opp.id)
            }
        }
    }

    /// Parse a pasted list into depth-tagged criteria. One criterion per line;
    /// leading indentation (spaces / tabs) nests a line under the nearest
    /// shallower one, to any depth; blank lines are skipped and common bullet
    /// markers (`*`, `-`, `•`, `1.`) are stripped. Commas are NOT separators —
    /// a criterion may contain commas.
    private func parseBulk(_ s: String) -> [(text: String, depth: Int)] {
        var out: [(String, Int)] = []
        var indent: [Int] = []
        for raw in s.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            var width = 0
            for ch in line {
                if ch == " " { width += 1 } else if ch == "\t" { width += 4 } else { break }
            }
            let text = stripBullet(line.trimmingCharacters(in: .whitespaces))
            guard !text.isEmpty else { continue }
            while let last = indent.last, last >= width { indent.removeLast() }
            out.append((text, indent.count))
            indent.append(width)
        }
        return out
    }

    /// Strip a single leading bullet / number marker from a line.
    private func stripBullet(_ s: String) -> String {
        var t = s
        if let f = t.first, "*-•·".contains(f) {
            t.removeFirst()
            return t.trimmingCharacters(in: .whitespaces)
        }
        // "1." / "1)" style
        let digits = t.prefix { $0.isNumber }
        if !digits.isEmpty {
            let after = t.dropFirst(digits.count)
            if let sep = after.first, sep == "." || sep == ")" {
                return after.dropFirst().trimmingCharacters(in: .whitespaces)
            }
        }
        return t
    }

    /// Split the inline add field into criteria — one per **line** only (commas
    /// are kept, since a criterion often contains them), stripping bullet markers.
    private func splitCriteria(_ s: String) -> [String] {
        s.split(separator: "\n")
            .map { stripBullet($0.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty }
    }

    private func commitAdd(_ opp: CatalogProject, _ poc: Poc) {
        let items = splitCriteria(newCriterion)
        guard !items.isEmpty else { return }
        let added = store.addPocCriteriaTexts(items, toPoc: poc.id, in: opp.id)
        newCriterion = ""
        if items.count > 1 {
            status = added == 0 ? "All already tracked."
                                : "Added \(added) criteri\(added == 1 ? "on" : "a")."
        } else {
            status = ""
        }
    }

    /// Bridge: read the project's linked meeting notes, extract POC success
    /// criteria, and add the new ones to this POC (deduped).
    private func suggestFromMeetings(_ opp: CatalogProject, _ poc: Poc) {
        let notes = store.notes(forProject: opp.id)
        let transcripts = notes.compactMap { store.url(of: $0).readText() }
        guard !transcripts.isEmpty else { status = "No readable meetings linked to this project."; return }
        let combined = String(transcripts.joined(separator: "\n\n---\n\n").prefix(40_000))
        let projID = opp.id, pid = poc.id
        suggesting = true
        status = "Reading \(transcripts.count) meeting\(transcripts.count == 1 ? "" : "s")…"
        Task { @MainActor in
            defer { suggesting = false }
            do {
                let criteria = try await TextPolisher().extractPocCriteria(transcript: combined)
                guard !criteria.isEmpty else { status = "No success criteria found in the linked meetings."; return }
                let added = store.addPocCriteriaTexts(criteria, toPoc: pid, in: projID)
                status = added == 0
                    ? "Found \(criteria.count) — all already tracked."
                    : "Added \(added) criteri\(added == 1 ? "on" : "a") from \(transcripts.count) meeting\(transcripts.count == 1 ? "" : "s")."
            } catch {
                status = "Suggest failed: \(error.localizedDescription)"
            }
        }
    }

}

// MARK: Small helpers
