import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Catalog Window
//
// A three-column browser over the catalog: sections → items → editor.
// Organisations form an unlimited hierarchy and their *relationship* is a
// property of the root (descendants inherit it). Projects belong to orgs;
// projects are hierarchical (sub-projects). Notes link to a project or an
// org; people and tags attach per note. The rest is inherited through the
// hierarchy, and a note's tags can be promoted into any entity.

final class CatalogWindowController: NSWindowController {
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.center()
        window.title = "Catalog"
        window.titlebarAppearsTransparent = true
        self.init(window: window)
        window.contentView = NSHostingView(rootView: CatalogView())
    }

}

// MARK: Sections

private enum CatalogSection: String, CaseIterable, Identifiable {
    // Declared in sidebar order so the enum and `sidebarGroups` can't drift:
    // Overview (where do I stand), then Records (everything captured), then
    // Track (the watch/resolve surfaces), then Explore (the graph lens).
    case dashboard     = "Dashboard"
    case reports       = "Reports"
    case notes         = "Notes"
    case organisations = "Organisations"
    case projects      = "Projects"
    case people        = "People"
    case tags          = "Tags"
    case questions     = "Open Questions"
    case poc           = "POC Tracker"
    case radar         = "Keyword Radar"
    case map           = "Map"
    var id: String { rawValue }

    /// Sidebar layout, grouped for scanning:
    /// • **Overview** — the "where do I stand" surfaces (Dashboard, Reports).
    /// • **Records** — every captured entity, led by Notes (the primary record),
    ///   then the deal-flow chain (org → project) kept contiguous to match the
    ///   Map tree, with People and Tags — cross-cutting per-note entities — last.
    /// • **Track** — the watch/resolve surfaces, led by the actionable inbox.
    /// • **Explore** — the graph lens over everything.
    static let sidebarGroups: [(title: String?, sections: [CatalogSection])] = [
        ("Overview", [.dashboard, .reports]),
        ("Records",  [.notes, .organisations, .projects, .people, .tags]),
        ("Track",    [.questions, .poc, .radar]),
        ("Explore",  [.map]),
    ]

    var singular: String {
        switch self {
        case .dashboard:     return "Dashboard"
        case .map:           return "Item"
        case .organisations: return "Organisation"
        case .people:        return "Person"
        case .projects:      return "Project"
        case .tags:          return "Tag"
        case .notes:         return "Note"
        case .poc:           return "POC"
        case .radar:         return "Term"
        case .questions:     return "Question"
        case .reports:       return "Report"
        }
    }
    var icon: String {
        switch self {
        case .dashboard:     return "square.grid.2x2.fill"
        case .map:           return "point.3.filled.connected.trianglepath.dotted"
        case .organisations: return "building.2"
        case .people:        return "person.2"
        case .projects:      return "folder"
        case .tags:          return "tag"
        case .notes:         return "doc.text"
        case .poc:           return "flask"
        case .radar:         return "dot.radiowaves.left.and.right"
        case .questions:     return "questionmark.circle"
        case .reports:       return "chart.bar.doc.horizontal"
        }
    }
    var tint: Color {
        switch self {
        case .dashboard:     return .accentColor
        case .map:           return .purple
        case .organisations: return .blue
        case .people:        return .teal
        case .projects:      return .orange
        case .tags:          return .pink
        case .notes:         return .indigo
        case .poc:           return .cyan
        case .radar:         return .red
        case .questions:     return .mint
        case .reports:       return .green
        }
    }
}

// MARK: Root

private struct CatalogView: View {
    @ObservedObject private var store = CatalogStore.shared
    @State private var section: CatalogSection = .dashboard
    @State private var selID: String?
    @State private var status = ""
    @State private var showQuickAdd = false
    @State private var showPurge = false
    @State private var showImportChoice = false
    @State private var pendingImportData: Data?
    @State private var mapSection: CatalogSection?
    @State private var mapID: String?
    @StateObject private var radarModel = RadarModel()
    // Notes search + filters (in the window toolbar).
    @State private var query = ""
    // Account/project scope uses the shared OrgProjectTreePicker (one control,
    // same as the dashboard & Open Questions). fOrg/fProject are derived from it.
    @State private var fScopeKind = ""   // "", "org", "project"
    @State private var fScopeID = ""
    private var fOrg: String { fScopeKind == "org" ? fScopeID : "" }
    private var fProject: String { fScopeKind == "project" ? fScopeID : "" }
    @State private var fTag = ""
    @State private var fPerson = ""
    @State private var fUnassigned = false
    @State private var fMissing = false
    @State private var fRange: DateRange = DateRange.defaultRange
    @State private var scope: NoteSearchScope = .text
    @State private var askNonce = 0
    private var anyFilter: Bool { !(fOrg.isEmpty && fProject.isEmpty && fTag.isEmpty && fPerson.isEmpty) || fUnassigned || fMissing }
    private var canAsk: Bool { !AppSettings.shared.localOnlyMode && KeychainService.groqAPIKey() != nil }

    /// Notes matching the active facet filters (ignoring the query — in Ask mode
    /// the query is the question). These scope what Ask retrieves from.
    private var askFiles: [NotesLibrary.MeetingFile] {
        store.doc.notes.filter { n in
            (fOrg.isEmpty || store.effectiveOrgIDs(of: n).contains(fOrg))
            && (fProject.isEmpty || store.effectiveProjectIDs(of: n).contains(fProject))
            && (fTag.isEmpty || n.tagIDs.contains(fTag))
            && (fPerson.isEmpty || n.personIDs.contains(fPerson))
            && (!fUnassigned || store.isUnassigned(n))
            && (!fMissing || !store.fileExists(n))
        }.map { NotesLibrary.MeetingFile(url: store.url(of: $0)) }
    }
    private var filterSummary: String {
        var parts: [String] = []
        if let o = store.org(fOrg) { parts.append(o.name) }
        if let p = store.project(fProject) { parts.append(p.name) }
        if let t = store.tag(fTag) { parts.append("#\(t.name)") }
        if let p = store.person(fPerson) { parts.append(p.name) }
        return parts.isEmpty ? "all \(store.doc.notes.count) notes" : parts.joined(separator: " · ")
    }

    private func count(_ s: CatalogSection) -> Int {
        switch s {
        case .dashboard:     return 0
        case .map:           return 0
        case .organisations: return store.doc.orgs.count
        case .people:        return store.doc.people.count
        case .projects:      return store.doc.projects.count
        case .tags:          return store.doc.tags.count
        case .notes:         return store.doc.notes.count
        case .poc:           return store.allPocs.count
        case .radar:         return 0
        case .questions:     return 0
        case .reports:       return 0
        }
    }

    /// Sections that fill the content column and want no detail pane.
    private var wideCanvas: Bool { section == .dashboard || section == .questions || section == .reports }
    /// Master lists that carry a filter/sort toolbar and so want a wider column.
    private var wideMaster: Bool { section == .poc || section == .radar || section == .map }

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                ForEach(CatalogSection.sidebarGroups, id: \.sections.first!.id) { group in
                    Section {
                        ForEach(group.sections) { s in
                            Label {
                                Text(s.rawValue)
                            } icon: {
                                Image(systemName: s.icon)
                                    .foregroundStyle(.white)
                                    .frame(width: 20, height: 20)
                                    .background(RoundedRectangle(cornerRadius: 5).fill(s.tint))
                            }
                            .badge(count(s) > 0 ? Text("\(count(s))") : nil)
                            .tag(s)
                        }
                    } header: {
                        if let title = group.title { Text(title) }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 178, ideal: 200, max: 230)
            .safeAreaInset(edge: .bottom) { importFooter }
        } content: {
            contentColumn
                // The Dashboard and Open Questions are wide canvases (they fill
                // this column); every other section is a normal master list, so
                // cap it narrower.
                .navigationSplitViewColumnWidth(
                    min: wideCanvas ? 460 : (wideMaster ? 330 : 240),
                    ideal: wideCanvas ? 640 : (wideMaster ? 370 : 285),
                    max: wideCanvas ? 5000 : (wideMaster ? 460 : 400))
                .navigationTitle(section.rawValue)
        } detail: {
            if wideCanvas {
                // Self-contained full-width sections — collapse the detail column
                // away so there's no blank pane on the right.
                Color.clear.frame(width: 0).navigationSplitViewColumnWidth(0)
            } else if section == .map {
                if let sec = mapSection, let id = mapID {
                    EntityEditorView(store: store, section: sec, id: id) { mapID = nil }
                        .id(id)
                        .frame(minWidth: 340)
                } else {
                    ContentUnavailableView("Catalog map", systemImage: "point.3.filled.connected.trianglepath.dotted",
                                           description: Text("Expand the tree and pick any item to open it here."))
                }
            } else if section == .poc {
                PocDetail(store: store, pocID: selID)
                    .frame(minWidth: 360)
            } else if section == .radar {
                RadarTermDetail(store: store, model: radarModel, term: selID)
            } else {
                EntityDetail(store: store, section: section, selID: $selID)
            }
        }
        .onChange(of: section) { _, _ in selID = nil; mapSection = nil; mapID = nil }
        .frame(minWidth: 900, minHeight: 520)
        .sheet(isPresented: $showQuickAdd) { QuickAddSheet(store: store) }
        .confirmationDialog("Purge the entire catalog?", isPresented: $showPurge, titleVisibility: .visible) {
            Button("Purge catalog", role: .destructive) {
                store.purgeAll(); selID = nil; mapSection = nil; mapID = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deletes every organisation, person, project, tag and note link. Your Markdown note files are not touched. This cannot be undone.")
        }
        .confirmationDialog("Import catalog", isPresented: $showImportChoice, titleVisibility: .visible) {
            Button("Merge into current") { runImport(.merge) }
            Button("Replace current…", role: .destructive) { runImport(.replace) }
            Button("Cancel", role: .cancel) { pendingImportData = nil }
        } message: {
            Text("Merge adds and updates records from the file, keeping everything else. Replace swaps your entire catalog for the file's contents. Your Markdown note files are never touched.")
        }
    }

    @ViewBuilder private var contentColumn: some View {
        if section == .dashboard {
            DashboardView(store: store) { section = .poc }
        } else if section == .radar {
            RadarTermList(store: store, model: radarModel, selID: $selID)
        } else if section == .map {
            MapTree(store: store) { sec, id in mapSection = sec; mapID = id }
        } else if section == .poc {
            PocProjectList(store: store, selID: $selID)
        } else if section == .questions {
            OpenQuestionsList(store: store)
        } else if section == .reports {
            ReportsView(store: store)
        } else if section == .notes {
            VStack(spacing: 0) {
                notesSearchHeader
                activeFilterBar
                Divider()
                Group {
                    if scope == .ask {
                        NoteAskView(store: store, question: query, nonce: askNonce,
                                    files: askFiles, filterSummary: filterSummary) { selID = $0 }
                    } else {
                        NotesList(store: store, selID: $selID, query: query, scope: scope,
                                  fOrg: fOrg, fProject: fProject, fTag: fTag, fPerson: fPerson,
                                  unassignedOnly: fUnassigned, missingOnly: fMissing, range: fRange)
                    }
                }
            }
        } else {
            EntityList(store: store, section: section, selID: $selID)
        }
    }

    /// Unified search + filter header atop the notes list: the search field, a
    /// labeled Text/Meaning/Ask scope, and the Filter button — all in one block
    /// so it reads as a single search system (removable filter chips sit just
    /// below via `activeFilterBar`).
    /// Placeholder tuned to the active search mode.
    private var searchPrompt: String {
        switch scope {
        case .text:    return "Search notes by keyword…"
        case .meaning: return "Search notes by meaning…"
        case .ask:     return "Ask a question about these notes…"
        }
    }

    private var notesSearchHeader: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: scope == .ask ? "sparkles" : "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField(searchPrompt, text: $query)
                        .textFieldStyle(.plain)
                        .onSubmit { if scope == .ask { askNonce += 1 } }
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.5)))

                // Compact time-window dropdown — a segmented control is too wide
                // for this narrow column. Hidden in Ask mode (answers over an
                // explicit file set rather than a dated list).
                if scope != .ask { RangePicker(range: $fRange, compact: true) }

                filterMenu
                    .menuStyle(.borderlessButton)
                    .fixedSize()

                if notesNonDefault {
                    ResetButton(help: "Reset search, filters & range", action: resetNotes)
                }
            }

            // Shared account/project scope — the same tree picker used by the
            // dashboard and Open Questions.
            OrgProjectTreePicker(store: store, kind: $fScopeKind, id: $fScopeID,
                                 allLabel: "All accounts & projects")

            Picker("Search type", selection: $scope) {
                Text("Text").tag(NoteSearchScope.text)
                if NotesLibrary.semanticAvailable { Text("Meaning").tag(NoteSearchScope.meaning) }
                if canAsk { Text("Ask").tag(NoteSearchScope.ask) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 6)
    }

    /// Number of active filters, for the toolbar badge.
    private var activeFilterCount: Int {
        [fOrg, fProject, fPerson, fTag].filter { !$0.isEmpty }.count
            + (fUnassigned ? 1 : 0) + (fMissing ? 1 : 0)
    }

    private func clearFilters() {
        fScopeKind = ""; fScopeID = ""; fTag = ""; fPerson = ""
        fUnassigned = false; fMissing = false
    }

    /// True when search, any facet, or the range is off-default.
    private var notesNonDefault: Bool {
        anyFilter || !query.trimmingCharacters(in: .whitespaces).isEmpty || fRange != DateRange.defaultRange
    }
    /// Reset the whole notes filter/search/range back to defaults.
    private func resetNotes() {
        clearFilters(); query = ""; fRange = DateRange.defaultRange
    }

    /// Single toolbar entry point for every note filter. Triage presets sit at
    /// the top (with live backlog counts), each facet is a submenu, and the
    /// whole thing badges itself with the active-filter count so state is
    /// visible without opening it.
    private var filterMenu: some View {
        Menu {
            let unassigned = store.unassignedNotes.count
            let missing = store.missingNotes.count
            if unassigned > 0 || fUnassigned {
                Button { fUnassigned.toggle() } label: {
                    Label("Unassigned (\(unassigned))", systemImage: fUnassigned ? "checkmark" : "tray")
                }
            }
            if missing > 0 || fMissing {
                Button { fMissing.toggle() } label: {
                    Label("Missing (\(missing))", systemImage: fMissing ? "checkmark" : "doc.badge.ellipsis")
                }
            }
            Divider()
            // Org/project scoping lives in the shared tree picker in the header;
            // the Filter menu keeps the remaining facets.
            facetSubmenu("Person", "person", $fPerson, store.doc.people.sortedByName.map { ($0.id, $0.name) })
            facetSubmenu("Tag", "tag", $fTag, store.tagsSorted.map { ($0.id, $0.name) })
            if anyFilter {
                Divider()
                Button("Clear all filters", role: .destructive) { clearFilters() }
            }
        } label: {
            Label(anyFilter ? "Filter (\(activeFilterCount))" : "Filter",
                  systemImage: anyFilter ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .help("Filter notes")
    }

    /// A single facet as a submenu inside the Filter menu; its label shows the
    /// current selection (or the facet name when unset).
    private func facetSubmenu(_ label: String, _ icon: String, _ sel: Binding<String>, _ options: [(String, String)]) -> some View {
        let current = options.first { $0.0 == sel.wrappedValue }?.1
        return Menu {
            Button("Any \(label)") { sel.wrappedValue = "" }
            if !options.isEmpty { Divider() }
            ForEach(options, id: \.0) { opt in
                Button {
                    sel.wrappedValue = (sel.wrappedValue == opt.0) ? "" : opt.0
                } label: {
                    if sel.wrappedValue == opt.0 { Label(opt.1, systemImage: "checkmark") } else { Text(opt.1) }
                }
            }
        } label: {
            Label(current ?? label, systemImage: icon)
        }
    }

    /// Slim bar under the search field that surfaces every active filter as a
    /// removable token. Hidden entirely when nothing is filtered.
    @ViewBuilder private var activeFilterBar: some View {
        if anyFilter {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    if let o = store.org(fOrg)         { filterChip(o.name, .blue)      { fScopeKind = ""; fScopeID = "" } }
                    if let p = store.project(fProject) { filterChip(p.name, .teal)      { fScopeKind = ""; fScopeID = "" } }
                    if let p = store.person(fPerson)   { filterChip(p.name, .purple)    { fPerson = "" } }
                    if let t = store.tag(fTag)         { filterChip("#\(t.name)", .pink) { fTag = "" } }
                    if fUnassigned { filterChip("Unassigned", .orange) { fUnassigned = false } }
                    if fMissing    { filterChip("Missing", .red)       { fMissing = false } }
                    Button("Clear all") { clearFilters() }
                        .buttonStyle(.plain)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 2)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            Divider()
        }
    }

    /// A removable filter token — tap anywhere on the capsule to clear it.
    private func filterChip(_ text: String, _ color: Color, remove: @escaping () -> Void) -> some View {
        Button(action: remove) {
            HStack(spacing: 3) {
                Text(text).lineLimit(1)
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .font(.caption2).fontWeight(.medium)
            .foregroundStyle(color)
            .pillBackground(color, opacity: 0.16, hPad: 7, vPad: 2)
        }
        .buttonStyle(.plain)
        .help("Remove filter")
    }

    private var importFooter: some View {
        VStack(spacing: 6) {
            Button { showQuickAdd = true } label: {
                Label("Quick add…", systemImage: "plus.rectangle.on.rectangle").frame(maxWidth: .infinity)
            }
            .controlSize(.small)
            .help("Create an organisation → project → people → tags in one go")
            Button {
                let n = store.indexNotesFolder()
                store.refresh()   // also re-checks existing rows against disk
                status = n > 0 ? "Imported \(n) note\(n == 1 ? "" : "s")" : "Up to date"
            } label: {
                Label("Import / reload", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
            }
            .controlSize(.small)
            .help("Scan the notes folder: add new meeting notes and re-check existing ones")
            if store.missingNotes.count > 0 {
                Button {
                    let n = store.pruneMissingNotes()
                    store.refresh()
                    status = n > 0 ? "Removed \(n) missing note\(n == 1 ? "" : "s")"
                                   : "All files present — nothing to remove"
                } label: {
                    Label("Clean up \(store.missingNotes.count) missing", systemImage: "wand.and.stars")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.small)
                .help("Remove entries whose file no longer exists. Files restored in Finder are re-checked first, not deleted.")
            }
            HStack(spacing: 6) {
                Button { exportCatalog() } label: {
                    Label("Export…", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                }
                .disabled(store.isEmpty)
                .help("Save the whole catalog to a JSON file — a portable backup you can move to another Mac")
                Button { importCatalog() } label: {
                    Label("Import…", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity)
                }
                .help("Load a previously exported catalog JSON — merge into or replace the current one")
            }
            .controlSize(.small)
            Button(role: .destructive) { showPurge = true } label: {
                Label("Purge catalog…", systemImage: "trash").frame(maxWidth: .infinity)
            }
            .controlSize(.small)
            .help("Delete all catalog data (note files are kept)")
            if !status.isEmpty { Text(status).font(.caption2).foregroundStyle(.secondary) }
        }
        .padding(10)
    }

    /// Write the catalog to a user-chosen `.json` file.
    private func exportCatalog() {
        guard let data = try? store.exportData() else { status = "Export failed"; return }
        if let s = FilePanels.save(defaultName: "Catalog.json", contentTypes: [.json],
                                   prompt: "Export", successVerb: "Exported", failVerb: "Export",
                                   write: { try data.write(to: $0, options: .atomic) }) {
            status = s
        }
    }

    /// Pick a `.json` file, validate it, then offer merge/replace.
    private func importCatalog() {
        guard let url = FilePanels.openFile(contentTypes: [.json], prompt: "Import"),
              let data = try? Data(contentsOf: url) else { return }
        guard store.isValidCatalog(data) else { status = "Not a valid catalog file"; return }
        pendingImportData = data
        showImportChoice = true
    }

    private func runImport(_ mode: CatalogStore.ImportMode) {
        guard let data = pendingImportData else { return }
        pendingImportData = nil
        do {
            let n = try store.importData(data, mode: mode)
            store.refresh()
            status = "Imported \(n) record\(n == 1 ? "" : "s")"
        } catch {
            status = "Import failed: \(error.localizedDescription)"
        }
    }
}

// MARK: Quick add — build a whole chain at once

struct QuickAddSheet: View {
    @ObservedObject var store: CatalogStore
    /// When set, called on finish with the resolved project id (or nil) —
    /// used by the Start Meeting flow. Otherwise the sheet just dismisses.
    var onComplete: ((String?) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    private static let new = "__new__"   // "＋ New …" sentinel

    // Org: an existing id or "__new__" (+ fields for the new case).
    @State private var orgSel = QuickAddSheet.new
    @State private var orgName = ""
    @State private var parentID = ""
    @State private var relationship: OrgRelationship = .customer
    // Project: "" (none), an existing id, or "__new__".
    @State private var projSel = ""
    @State private var projName = ""
    // People / Tags: existing selections + new comma-separated names.
    @State private var selectedPeople: Set<String> = []
    @State private var newPeople = ""
    @State private var selectedTags: Set<String> = []
    @State private var newTags = ""

    private var orgIsNew: Bool { orgSel == Self.new }
    /// The existing org chosen (nil when creating a new one).
    private var existingOrgID: String? { orgIsNew ? nil : orgSel }
    private var canAdd: Bool { !orgIsNew || !orgName.trimmingCharacters(in: .whitespaces).isEmpty }

    private var projectsForOrg: [CatalogProject] {
        guard let id = existingOrgID else { return [] }
        // Every project under this org, including sub-projects, so the whole
        // hierarchy is pickable.
        return store.doc.projects
            .filter { store.org(forProject: $0.id)?.id == id }
            .sortedByName
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Organisation") {
                    Picker("Organisation", selection: $orgSel) {
                        ForEach(store.orgsSorted) { Text(store.orgPath(of: $0.id)).tag($0.id) }
                        Divider()
                        Text("＋ New organisation").tag(Self.new)
                    }
                    if orgIsNew {
                        TextField("New name", text: $orgName)
                        Picker("Parent", selection: $parentID) {
                            Text("None (top level)").tag("")
                            ForEach(store.orgsSorted) { Text(store.orgPath(of: $0.id)).tag($0.id) }
                        }
                        Picker("Relationship", selection: $relationship) {
                            ForEach(OrgRelationship.allCases) { Text($0.label).tag($0) }
                        }
                    }
                }
                Section("Project") {
                    Picker("Project", selection: $projSel) {
                        Text("None").tag("")
                        ForEach(projectsForOrg) { Text(store.projectPath(of: $0.id)).tag($0.id) }
                        Divider()
                        Text("＋ New project").tag(Self.new)
                    }
                    if projSel == Self.new { TextField("New name", text: $projName) }
                }
                Section("People") {
                    pickExisting(store.doc.people.sortedByName.map { ($0.id, $0.name) }, $selectedPeople)
                    TextField("＋ New, comma-separated", text: $newPeople)
                }
                Section("Tags") {
                    pickExisting(store.tagsSorted.map { ($0.id, $0.name) }, $selectedTags)
                    TextField("＋ New, comma-separated", text: $newTags)
                }
            }
            .formStyle(.grouped)
            .onChange(of: orgSel) { _, _ in projSel = "" }
            Divider()
            HStack {
                Text("Pick existing entries or type new ones; links them together.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { finish(nil) }
                Button("Add") { add() }.keyboardShortcut(.defaultAction).disabled(!canAdd)
            }
            .padding(12)
        }
        .frame(width: 440, height: 520)
    }

    /// A capped, scrolling list of existing items as multi-select toggles.
    private func pickExisting(_ items: [(id: String, name: String)], _ sel: Binding<Set<String>>) -> some View {
        Group {
            if items.isEmpty {
                Text("None yet.").font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(items, id: \.id) { item in
                            Toggle(item.name, isOn: Binding(
                                get: { sel.wrappedValue.contains(item.id) },
                                set: { on in if on { sel.wrappedValue.insert(item.id) } else { sel.wrappedValue.remove(item.id) } }))
                        }
                    }
                }
                .frame(height: items.count > 4 ? 96 : nil)
            }
        }
    }

    private func add() {
        // Organisation — existing or new.
        let orgID: String
        if let existing = existingOrgID {
            orgID = existing
        } else {
            let name = orgName.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return }
            var o = store.addOrg(name: name, relationship: relationship)
            if !parentID.isEmpty { o.parentID = parentID; store.update(o) }
            orgID = o.id
        }

        // Project — existing, new (under the org), or none.
        var projectID: String?
        if projSel == Self.new {
            let name = projName.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { projectID = store.addProject(name: name, orgID: orgID).id }
        } else if !projSel.isEmpty {
            projectID = projSel
        }

        // People are org-independent — existing selections already exist; just
        // create any new names so they're available to pick on notes.
        for name in splitList(newPeople) { _ = store.addPerson(name: name) }

        // Tags — existing selections already exist; just create the new ones.
        for name in splitList(newTags) { _ = store.addTag(name: name) }

        finish(projectID)
    }

    private func finish(_ projectID: String?) {
        if let onComplete { onComplete(projectID) } else { dismiss() }
    }
}

// MARK: Helpers

private func openNote(_ note: CatalogNote) {
    let url = AppSettings.shared.notesFolder.appendingPathComponent(note.filePath)
    NotesViewerWindowController.present(fileURL: url)
}

/// Compact inline search field with a clear button — the catalog's shared
/// filter control for record lists and the note-assignment pickers.
struct EntitySearchBar: View {
    @Binding var text: String
    var placeholder: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.secondary)
            TextField(placeholder, text: $text).textFieldStyle(.plain)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain).help("Clear search")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .quaternaryLabelColor).opacity(0.5)))
    }
}

private struct NoteRow: View {
    let note: CatalogNote
    var body: some View {
        Button { openNote(note) } label: {
            HStack(spacing: 8) {
                Image(systemName: "doc.text").foregroundStyle(.secondary)
                Text(note.title).lineLimit(1)
                Spacer()
                Image(systemName: "arrow.up.forward").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
    }
}

/// One row in a relationship timeline: date + title, opens the note. Rows are
/// expected to be fed newest-first by the caller.
private struct TimelineRow: View {
    let note: CatalogNote
    var body: some View {
        Button { openNote(note) } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(note.title).lineLimit(1)
                    if let d = note.date {
                        Text(d.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "arrow.up.forward").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
    }
}

/// Chronological (newest-first) list of an org's or person's notes — the
/// relationship history at a glance.
private struct RelationshipTimeline: View {
    let notes: [CatalogNote]
    var body: some View {
        ForEach(notes.sortedByDateDescending) { TimelineRow(note: $0) }
    }
}

/// On-demand AI digest across an entity's recent notes — "where things stand".
/// Reads up to the 5 most recent notes and opens the summary in its own window.
private struct RelationshipSummaryButton: View {
    @ObservedObject var store: CatalogStore
    let entityName: String
    let notes: [CatalogNote]
    @State private var working = false
    @State private var status = ""

    private var canRun: Bool { !AppSettings.shared.localOnlyMode && !notes.isEmpty }


    var body: some View {
        if canRun {
            Button { run() } label: {
                Label(working ? "Summarizing…" : "Summarize relationship", systemImage: "sparkles")
            }
            .disabled(working)
            Text("Reads the 5 most recent notes and opens a cross-meeting digest in a new window.")
                .font(.caption).foregroundStyle(.secondary)
            if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.red.opacity(0.8)) }
        }
    }

    private func run() {
        working = true; status = ""
        let recent = notes.sortedByDateDescending.prefix(5)
        let entries = recent.map { (title: $0.title, url: store.url(of: $0)) }
        let name = entityName
        Task { @MainActor in
            defer { working = false }
            do {
                let (digest, lastError) = try await Self.buildDigest(entries: entries, forceRefresh: false)
                // Two blank lines between meetings.
                NotesViewerWindowController.present(
                    draftTitle: "Relationship — \(name)", text: digest,
                    regenerate: {
                        let (fresh, _) = try await Self.buildDigest(entries: entries, forceRefresh: true)
                        return fresh
                    })
                if let lastError { status = "Some meetings were skipped (\(lastError))." }
            } catch {
                status = "Summary failed: \(error.localizedDescription)"
            }
        }
    }

    /// Digest the given notes into one block per meeting. Skips a note that
    /// fails (e.g. a transient rate limit) so the rest still open. Throws only
    /// when nothing could be digested at all. `forceRefresh` bypasses the cache.
    private static func buildDigest(entries: [(title: String, url: URL)],
                                    forceRefresh: Bool) async throws -> (text: String, lastError: String?) {
        let polisher = TextPolisher()
        var blocks: [String] = []
        var lastError: String?
        for e in entries {
            guard let text = e.url.readText(), !text.isEmpty else { continue }
            do {
                let body = try await polisher.noteBrief(text: text, forceRefresh: forceRefresh)
                blocks.append("\(e.title)\n\(TextPolisher.spacedBrief(body))")
            } catch {
                lastError = error.localizedDescription
            }
        }
        guard !blocks.isEmpty else {
            throw GroqError.apiError(statusCode: 0, message: lastError ?? "no note content to summarize.")
        }
        return (blocks.joined(separator: "\n\n\n"), lastError)
    }
}

private struct EmptyDetail: View {
    let section: CatalogSection
    var body: some View {
        ContentUnavailableView("No \(section.singular) selected",
                               systemImage: section.icon,
                               description: Text("Pick one from the list, or add a new \(section.singular.lowercased())."))
    }
}

// MARK: Content column

private struct EntityList: View {
    @ObservedObject var store: CatalogStore
    let section: CatalogSection
    @Binding var selID: String?
    @State private var search = ""
    @State private var showManageTypes = false
    // Bulk multi-select (People & Tags only).
    @State private var selecting = false
    @State private var multiSel = Set<String>()
    @State private var showBulkAdd = false

    /// Bulk add / delete / assign applies to the flat managed vocabularies.
    private var bulkEligible: Bool { section == .people || section == .tags }

    /// Case-insensitive substring match against the live search box.
    private func matches(_ name: String) -> Bool {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty || name.lowercased().contains(q)
    }

    var body: some View {
        VStack(spacing: 0) {
            EntitySearchBar(text: $search, placeholder: "Search \(section.rawValue.lowercased())")
                .padding(.horizontal, 8).padding(.vertical, 6)
            Divider()
            Group {
                switch section {
                case .dashboard, .map, .notes, .poc, .radar, .questions, .reports: EmptyView()   // handled by CatalogView
                case .organisations: orgList
                case .people:        peopleList
                case .projects:      projectList
                case .tags:          tagList
                }
            }
            if selecting && bulkEligible { bulkBar }
        }
        .toolbar {
            if section == .people {
                ToolbarItem {
                    Button { showManageTypes = true } label: { Label("Types", systemImage: "person.2.badge.gearshape") }
                        .help("Manage people types")
                }
            }
            if bulkEligible {
                ToolbarItem {
                    Button { showBulkAdd = true } label: { Label("Bulk Add", systemImage: "text.badge.plus") }
                        .help("Add several \(section.rawValue.lowercased()) at once")
                }
                ToolbarItem {
                    Button {
                        selecting.toggle(); multiSel.removeAll()
                    } label: { Label("Select", systemImage: selecting ? "checkmark.circle.fill" : "checkmark.circle") }
                        .help("Select multiple to delete or reassign")
                }
            }
            if section != .notes {
                ToolbarItem {
                    Button { add() } label: { Label("Add", systemImage: "plus") }
                        .help("Add \(section.singular)")
                }
            }
        }
        .sheet(isPresented: $showManageTypes) { ManageTypesSheet(store: store) }
        .sheet(isPresented: $showBulkAdd) {
            BulkAddSheet(store: store, section: section)
        }
    }

    /// The set of *real* selected record ids (person/tag), excluding the
    /// synthetic type-header rows that share the People list.
    private var selectedIDs: [String] {
        let valid: Set<String> = section == .people
            ? Set(store.doc.people.map { $0.id })
            : Set(store.doc.tags.map { $0.id })
        return multiSel.filter { valid.contains($0) }.map { $0 }
    }

    /// Action bar shown under the list while selecting multiple records.
    private var bulkBar: some View {
        let ids = selectedIDs
        return VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                Text(ids.isEmpty ? "Select items" : "\(ids.count) selected")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                if section == .people {
                    Menu {
                        Button("No type") { store.setPersonType(ids, to: nil) }
                        Divider()
                        ForEach(store.personTypesSorted) { t in
                            Button(store.personTypePath(of: t.id)) { store.setPersonType(ids, to: t.id) }
                        }
                    } label: { Label("Set Type", systemImage: "tag") }
                        .disabled(ids.isEmpty).fixedSize()
                }
                Button(role: .destructive) {
                    if section == .people { store.deletePeople(ids) } else { store.deleteTags(ids) }
                    multiSel.removeAll()
                } label: { Label("Delete", systemImage: "trash") }
                    .disabled(ids.isEmpty)
                Button("Done") { selecting = false; multiSel.removeAll() }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .background(.bar)
    }

    private var orgList: some View {
        func rows(_ orgs: [CatalogOrg], _ depth: Int) -> [(CatalogOrg, Int)] {
            orgs.flatMap { [($0, depth)] + rows(store.childOrgs(of: $0.id), depth + 1) }
        }
        // While filtering, flatten to just the matches (tree indent would be
        // misleading when parents are hidden).
        let all = rows(store.rootOrgs, 0)
        let filtered = search.isEmpty ? all : all.filter { matches($0.0.name) }.map { ($0.0, 0) }
        return List(selection: $selID) {
            ForEach(filtered, id: \.0.id) { org, depth in
                HStack(spacing: 6) {
                    if depth > 0 {
                        Image(systemName: "arrow.turn.down.right").font(.caption2).foregroundStyle(.tertiary)
                    }
                    Text(org.name)
                    Spacer()
                    RelationshipBadge(org.relationship)
                }
                .padding(.leading, CGFloat(depth) * 12)
                .tag(org.id)
            }
        }
    }

    /// One rendered line of the People list — either a type header (grouping) or
    /// a person under it. Depth drives indentation, mirroring the org/project
    /// trees. People with no type collect under a trailing "No type" header.
    private enum PeopleRow: Identifiable {
        case type(CatalogPersonType, depth: Int)
        case person(CatalogPerson, depth: Int)
        var id: String {
            switch self {
            case .type(let t, _):   return "type:\(t.id)"
            case .person(let p, _): return p.id
            }
        }
    }

    /// Pre-order walk of the type hierarchy, each type followed by its people
    /// then its sub-types; untyped people last under a synthetic header.
    private var peopleRows: [PeopleRow] {
        var out: [PeopleRow] = []
        func walk(_ type: CatalogPersonType, _ depth: Int) {
            out.append(.type(type, depth: depth))
            for p in store.people(ofType: type.id) { out.append(.person(p, depth: depth + 1)) }
            for child in store.childPersonTypes(of: type.id) { walk(child, depth + 1) }
        }
        for root in store.rootPersonTypes { walk(root, 0) }
        let untyped = store.people(ofType: nil)
        if !untyped.isEmpty {
            out.append(.type(CatalogPersonType(id: "__none__", name: "No type"), depth: 0))
            for p in untyped { out.append(.person(p, depth: 1)) }
        }
        return out
    }

    @ViewBuilder private func peopleRowView(_ row: PeopleRow) -> some View {
        switch row {
        case .type(let t, let depth):
            HStack(spacing: 6) {
                Image(systemName: t.id == "__none__" ? "person.crop.circle.badge.questionmark" : "person.2.badge.gearshape")
                    .font(.caption2).foregroundStyle(.tertiary)
                Text(t.name).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            .padding(.leading, CGFloat(depth) * 14).padding(.top, 2)
        case .person(let p, let depth):
            Text(p.name).padding(.leading, CGFloat(depth) * 14).tag(p.id)
        }
    }

    private var peopleList: some View {
        // While searching, flatten to matching people only (type headers would be
        // misleading with parents hidden) — same rule as the org list.
        let rows: [PeopleRow] = search.isEmpty
            ? peopleRows
            : store.doc.people.sortedByName.filter { matches($0.name) }.map { .person($0, depth: 0) }
        return Group {
            if selecting {
                List(rows, selection: $multiSel) { peopleRowView($0) }
            } else {
                List(rows, selection: $selID) { peopleRowView($0) }
            }
        }
    }

    /// Projects grouped by their organisation, then by project name.
    /// Projects laid out as a hierarchy: each root project (grouped by its org)
    /// followed by its sub-projects, depth-first, tagged with a depth for
    /// indentation.
    private var sortedProjects: [(project: CatalogProject, depth: Int)] {
        func children(of parent: String?) -> [CatalogProject] {
            store.doc.projects.filter { $0.parentID == parent }
        }
        // Roots (no parent) sorted by org path then name.
        let roots = children(of: nil).sorted { a, b in
            let oa = store.org(a.orgID).map { store.orgPath(of: $0.id) } ?? "~"
            let ob = store.org(b.orgID).map { store.orgPath(of: $0.id) } ?? "~"
            if oa.caseInsensitiveCompare(ob) != .orderedSame {
                return oa.localizedCaseInsensitiveCompare(ob) == .orderedAscending
            }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        var out: [(CatalogProject, Int)] = []
        func walk(_ p: CatalogProject, _ depth: Int) {
            out.append((p, depth))
            for c in children(of: p.id).sortedByName { walk(c, depth + 1) }
        }
        for r in roots { walk(r, 0) }
        return out.map { (project: $0.0, depth: $0.1) }
    }

    private var projectList: some View {
        List(sortedProjects.filter { matches($0.project.name) }, id: \.project.id, selection: $selID) { row in
            let p = row.project
            HStack(spacing: 6) {
                if row.depth > 0 {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.caption2).foregroundStyle(.secondary)
                        .padding(.leading, CGFloat(row.depth - 1) * 14)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.name).lineLimit(1)
                    Text(store.org(forProject: p.id).map { store.orgPath(of: $0.id) } ?? "No organisation")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.vertical, 3)
            .tag(p.id)
        }
    }

    @ViewBuilder private func tagRowView(_ t: CatalogTag) -> some View {
        HStack {
            Text(t.name)
            Spacer()
            Text("\(store.notes(forTag: t.id).count)").font(.caption).foregroundStyle(.secondary)
        }.tag(t.id)
    }

    private var tagList: some View {
        let tags = store.tagsSorted.filter { matches($0.name) }
        return Group {
            if selecting {
                List(tags, selection: $multiSel) { tagRowView($0) }
            } else {
                List(tags, selection: $selID) { tagRowView($0) }
            }
        }
    }

    private func add() {
        switch section {
        case .map:           break
        case .organisations: selID = store.addOrg(name: "New Organisation").id
        case .people:        selID = store.addPerson(name: "New Person").id
        case .projects:      selID = store.addProject(name: "New Project").id
        case .tags:
            // addTag folds by name, so pick a name that doesn't already exist —
            // otherwise "+" would just re-select the existing "New Tag".
            let existing = Set(store.doc.tags.map { $0.name.lowercased() })
            var name = "New Tag", n = 2
            while existing.contains(name.lowercased()) { name = "New Tag \(n)"; n += 1 }
            selID = store.addTag(name: name).id
        case .dashboard, .notes, .poc, .radar, .questions, .reports:   break
        }
    }
}

// MARK: Detail column

private struct EntityDetail: View {
    @ObservedObject var store: CatalogStore
    let section: CatalogSection
    @Binding var selID: String?

    var body: some View {
        Group {
            if let id = selID {
                EntityEditorView(store: store, section: section, id: id) { selID = nil }.id(id)
            } else {
                EmptyDetail(section: section)
            }
        }
        .frame(minWidth: 340)
    }
}

/// The editor for one entity, chosen by section + id. Shared by the normal
/// detail column and the Map's inline detail.
private struct EntityEditorView: View {
    @ObservedObject var store: CatalogStore
    let section: CatalogSection
    let id: String
    var onDelete: () -> Void

    var body: some View {
        switch section {
        case .dashboard, .map, .poc, .radar, .questions, .reports: EmptyView()
        case .organisations:
            if let o = store.org(id) { OrgEditor(store: store, org: o, onDelete: onDelete) } else { missing }
        case .people:
            if let p = store.person(id) { PersonEditor(store: store, person: p, onDelete: onDelete) } else { missing }
        case .projects:
            if let p = store.project(id) { ProjectEditor(store: store, project: p, onDelete: onDelete) } else { missing }
        case .tags:
            if let t = store.tag(id) { TagEditor(store: store, tag: t, onDelete: onDelete) } else { missing }
        case .notes:
            if let n = store.note(id: id) { NoteLinkEditor(store: store, note: n) } else { missing }
        }
    }
    private var missing: some View {
        ContentUnavailableView("Deleted", systemImage: "trash", description: Text("This item no longer exists."))
    }
}

// MARK: Badges

/// A tinted capsule label — the one pill style used for relationship/stage
/// badges and the note-list status chips.
struct CapsulePill: View {
    let text: String
    let color: Color
    var body: some View { TintedPill(text: text, tint: color) }
}

private struct RelationshipBadge: View {
    let rel: OrgRelationship
    init(_ r: OrgRelationship) { rel = r }
    var body: some View { CapsulePill(text: rel.label, color: color) }
    private var color: Color {
        switch rel {
        case .root:     return .blue
        case .customer: return .green
        case .prospect: return .orange
        case .partner:  return .purple
        case .internalOrg: return .gray
        case .other:    return .secondary
        }
    }
}

private struct StageBadge: View {
    let stage: OppStage
    init(_ s: OppStage) { stage = s }
    var body: some View { CapsulePill(text: stage.label, color: color) }
    private var color: Color {
        switch stage {
        case .open: return .blue
        case .won:  return .green
        case .lost: return .red
        }
    }
}

// MARK: Organisation editor

private struct OrgEditor: View {
    @ObservedObject var store: CatalogStore
    @State private var draft: CatalogOrg
    var onDelete: () -> Void

    init(store: CatalogStore, org: CatalogOrg, onDelete: @escaping () -> Void) {
        self.store = store; _draft = State(initialValue: org); self.onDelete = onDelete
    }
    private func commit() { store.update(draft) }

    private var aliasText: Binding<String> {
        Binding(get: { draft.aliases.joined(separator: ", ") }, set: { draft.aliases = splitList($0) })
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $draft.name).onSubmit(commit)
                LabeledContent("Parent") {
                    OrgProjectTreePicker(
                        store: store,
                        kind: .constant(draft.parentID == nil ? "" : "org"),
                        id: Binding(get: { draft.parentID ?? "" },
                                    set: { draft.parentID = $0.isEmpty ? nil : $0; commit() }),
                        allLabel: "None (top level)", allIcon: "arrow.up.to.line.compact",
                        scope: .orgsOnly, excluding: store.orgSubtree(of: draft.id))
                }
                Picker("Relationship", selection: Binding(
                    get: { draft.relationship },
                    set: { draft.relationship = $0; commit() })) {
                    ForEach(OrgRelationship.allCases) { Text($0.label).tag($0) }
                }
            }
            Section("Aliases") {
                TextField("Comma-separated", text: aliasText).onSubmit(commit)
                Text("Spoken/company names that resolve to this org.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Notes") {
                TextField("Free notes", text: $draft.notes, axis: .vertical).lineLimit(2...6).onSubmit(commit)
            }
            let people = store.peopleFromNotes(forOrg: draft.id)
            if !people.isEmpty { Section("People (from notes)") { ForEach(people) { Text($0.name) } } }
            let projects = store.projects(forOrg: draft.id)
            if !projects.isEmpty { Section("Projects") { ForEach(projects) { Text($0.name) } } }
            let notes = store.notes(forOrg: draft.id, includingDescendants: true)
            if !notes.isEmpty {
                Section("Relationship") { RelationshipSummaryButton(store: store, entityName: draft.name, notes: notes) }
                Section("Timeline (incl. sub-orgs)") { RelationshipTimeline(notes: notes) }
            }
            Section { Button("Delete Organisation", role: .destructive) { store.deleteOrg(draft.id); onDelete() } }
        }
        .formStyle(.grouped)
        .navigationTitle(draft.name.isEmpty ? "Organisation" : draft.name)
        .onDisappear(perform: commit)
    }
}

// MARK: Person editor

private struct PersonEditor: View {
    @ObservedObject var store: CatalogStore
    @State private var draft: CatalogPerson
    var onDelete: () -> Void

    init(store: CatalogStore, person: CatalogPerson, onDelete: @escaping () -> Void) {
        self.store = store; _draft = State(initialValue: person); self.onDelete = onDelete
    }
    private func commit() { store.update(draft) }
    @State private var showManageTypes = false

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $draft.name).onSubmit(commit)
                LabeledContent("Type") {
                    PersonTypePicker(store: store, selection: Binding(
                        get: { draft.typeID },
                        set: { draft.typeID = $0; commit() }),
                        onManage: { showManageTypes = true })
                }
                TextField("Email", text: Binding(
                    get: { draft.email ?? "" },
                    set: { draft.email = $0.isEmpty ? nil : $0 })).onSubmit(commit)
            }
            let notes = store.notes(forPerson: draft.id)
            if !notes.isEmpty {
                Section("Timeline") { RelationshipTimeline(notes: notes) }
            }
            Section { Button("Delete Person", role: .destructive) { store.deletePerson(draft.id); onDelete() } }
        }
        .formStyle(.grouped)
        .navigationTitle(draft.name.isEmpty ? "Person" : draft.name)
        .onDisappear(perform: commit)
        .sheet(isPresented: $showManageTypes) { ManageTypesSheet(store: store) }
    }
}

// MARK: Person type picker & management

/// A hierarchical menu picker over the managed person-type vocabulary, with
/// "None" and a shortcut to the management sheet. Shared by the person editor
/// and the bulk "Set type" action.
private struct PersonTypePicker: View {
    @ObservedObject var store: CatalogStore
    @Binding var selection: String?
    var onManage: (() -> Void)? = nil

    var body: some View {
        Menu {
            Button { selection = nil } label: {
                Label("None", systemImage: selection == nil ? "checkmark" : "")
            }
            Divider()
            ForEach(store.rootPersonTypes) { typeMenu($0) }
            if let onManage {
                Divider()
                Button { onManage() } label: { Label("Manage Types…", systemImage: "slider.horizontal.3") }
            }
        } label: {
            Text(selection.flatMap { store.personTypePath(of: $0) } ?? "None")
                .foregroundStyle(selection == nil ? .secondary : .primary)
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    // Recursive, so the return type is erased to break the self-referential
    // opaque-type inference.
    private func typeMenu(_ t: CatalogPersonType) -> AnyView {
        let kids = store.childPersonTypes(of: t.id)
        if kids.isEmpty {
            return AnyView(Button { selection = t.id } label: {
                Label(t.name, systemImage: selection == t.id ? "checkmark" : "")
            })
        }
        // A parent is both selectable and a submenu of its children.
        return AnyView(Menu {
            Button { selection = t.id } label: {
                Label("\(t.name) (this)", systemImage: selection == t.id ? "checkmark" : "")
            }
            Divider()
            ForEach(kids) { typeMenu($0) }
        } label: { Text(t.name) })
    }
}

/// Add / rename / reparent / delete the person-type vocabulary. Presented as a
/// sheet from the person editor and the People toolbar.
private struct ManageTypesSheet: View {
    @ObservedObject var store: CatalogStore
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var newParent: String? = nil

    private var rows: [(type: CatalogPersonType, depth: Int)] {
        var out: [(CatalogPersonType, Int)] = []
        func walk(_ t: CatalogPersonType, _ d: Int) {
            out.append((t, d))
            for c in store.childPersonTypes(of: t.id) { walk(c, d + 1) }
        }
        for r in store.rootPersonTypes { walk(r, 0) }
        return out.map { (type: $0.0, depth: $0.1) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("People Types").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }.padding()
            Divider()
            List {
                ForEach(rows, id: \.type.id) { row in
                    HStack(spacing: 6) {
                        if row.depth > 0 {
                            Image(systemName: "arrow.turn.down.right").font(.caption2).foregroundStyle(.tertiary)
                        }
                        TextField("Name", text: Binding(
                            get: { row.type.name },
                            set: { var t = row.type; t.name = $0; store.update(t) }))
                        Spacer()
                        Text("\(store.people(ofType: row.type.id).count)")
                            .font(.caption).foregroundStyle(.secondary)
                        // Reparent (excluding self + descendants to avoid cycles).
                        Menu {
                            Button { var t = row.type; t.parentID = nil; store.update(t) } label: {
                                Label("Top level", systemImage: row.type.parentID == nil ? "checkmark" : "")
                            }
                            let banned = store.personTypeSubtree(of: row.type.id)
                            ForEach(store.personTypesSorted.filter { !banned.contains($0.id) }) { p in
                                Button { var t = row.type; t.parentID = p.id; store.update(t) } label: {
                                    Label(store.personTypePath(of: p.id), systemImage: row.type.parentID == p.id ? "checkmark" : "")
                                }
                            }
                        } label: { Image(systemName: "arrow.up.and.down.text.horizontal") }
                            .menuStyle(.borderlessButton).fixedSize()
                        Button(role: .destructive) { store.deletePersonType(row.type.id) } label: {
                            Image(systemName: "trash")
                        }.buttonStyle(.borderless)
                    }
                    .padding(.leading, CGFloat(row.depth) * 14)
                }
            }
            Divider()
            HStack(spacing: 8) {
                TextField("New type name", text: $newName).onSubmit(add)
                Picker("", selection: $newParent) {
                    Text("Top level").tag(String?.none)
                    ForEach(store.personTypesSorted) { Text(store.personTypePath(of: $0.id)).tag(String?.some($0.id)) }
                }.labelsHidden().fixedSize()
                Button("Add") { add() }.disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }.padding()
        }
        .frame(width: 460, height: 420)
    }

    private func add() {
        let n = newName.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        store.addPersonType(name: n, parentID: newParent)
        newName = ""
    }
}

/// Paste-many creator for People or Tags: one name per line. For People an
/// optional type is applied to all created rows. Existing names are skipped, so
/// the sheet is safe to reuse.
private struct BulkAddSheet: View {
    @ObservedObject var store: CatalogStore
    let section: CatalogSection
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var typeID: String? = nil

    private var noun: String { section == .people ? "People" : "Tags" }
    private var names: [String] {
        text.split(whereSeparator: \.isNewline).map(String.init)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Bulk Add \(noun)").font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding()
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("One name per line.").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $text)
                    .font(.body.monospaced())
                    .frame(minHeight: 180)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                if section == .people {
                    LabeledContent("Type for all") {
                        PersonTypePicker(store: store, selection: $typeID)
                    }
                }
            }.padding()
            Divider()
            HStack {
                Text("\(names.count) name\(names.count == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Add") {
                    if section == .people { store.addPeople(names: names, typeID: typeID) }
                    else { store.addTags(names: names) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction).disabled(names.isEmpty)
            }.padding()
        }
        .frame(width: 460, height: 420)
    }
}

/// Assign **multiple** tags and people to a batch of notes in one pass, with an
/// optional org/project filing. Each picked tag/person is *added* (union) to
/// every selected note; filing overwrites (mutually exclusive, per the model).
private struct BulkAssignSheet: View {
    @ObservedObject var store: CatalogStore
    let noteIDs: [String]
    @Environment(\.dismiss) private var dismiss
    @State private var pickedTags = Set<String>()
    @State private var pickedPeople = Set<String>()
    @State private var fileKind = ""          // "", "org", "project"
    @State private var fileID = ""
    @State private var tagQuery = ""
    @State private var personQuery = ""

    private func match(_ name: String, _ q: String) -> Bool {
        let t = q.trimmingCharacters(in: .whitespaces).lowercased()
        return t.isEmpty || name.lowercased().contains(t)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Assign to \(noteIDs.count) note\(noteIDs.count == 1 ? "" : "s")").font(.headline)
                    Text("Pick any number of tags and people.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding()
            Divider()
            HStack(alignment: .top, spacing: 0) {
                pickColumn(title: "Tags", query: $tagQuery,
                           items: store.tagsSorted.filter { match($0.name, tagQuery) }.map { ($0.id, $0.name) },
                           picked: $pickedTags, empty: "No tags yet")
                Divider()
                pickColumn(title: "People", query: $personQuery,
                           items: store.doc.people.sortedByName.filter { match($0.name, personQuery) }.map { ($0.id, $0.name) },
                           picked: $pickedPeople, empty: "No people yet")
            }
            .frame(height: 300)
            Divider()
            HStack(spacing: 8) {
                Text("File under").font(.callout)
                OrgProjectTreePicker(
                    store: store,
                    kind: $fileKind,
                    id: Binding(get: { fileID }, set: { fileID = $0 }),
                    allLabel: "Leave as-is", allIcon: "minus")
                Spacer()
            }.padding(.horizontal).padding(.vertical, 8)
            Divider()
            HStack {
                Spacer()
                Button("Apply") { apply(); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(pickedTags.isEmpty && pickedPeople.isEmpty && fileID.isEmpty)
            }.padding()
        }
        .frame(width: 560, height: 520)
    }

    /// A titled, searchable, multi-select column of toggle rows.
    private func pickColumn(title: String, query: Binding<String>,
                            items: [(id: String, name: String)],
                            picked: Binding<Set<String>>, empty: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                if !picked.wrappedValue.isEmpty {
                    Text("\(picked.wrappedValue.count)").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 12).padding(.top, 8)
            EntitySearchBar(text: query, placeholder: "Search \(title.lowercased())").padding(.horizontal, 8)
            if items.isEmpty {
                Spacer(); Text(empty).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity); Spacer()
            } else {
                List {
                    ForEach(items, id: \.id) { item in
                        Button {
                            if picked.wrappedValue.contains(item.id) { picked.wrappedValue.remove(item.id) }
                            else { picked.wrappedValue.insert(item.id) }
                        } label: {
                            HStack {
                                Image(systemName: picked.wrappedValue.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(picked.wrappedValue.contains(item.id) ? Color.accentColor : .secondary)
                                Text(item.name); Spacer()
                            }
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func apply() {
        for t in pickedTags { store.addTag(t, toNotes: noteIDs) }
        for p in pickedPeople { store.addPerson(p, toNotes: noteIDs) }
        if !fileID.isEmpty {
            if fileKind == "project" { store.fileNotes(noteIDs, underProject: fileID) }
            else if fileKind == "org" { store.fileNotes(noteIDs, underOrg: fileID) }
        }
    }
}

// MARK: Project editor

private struct ProjectEditor: View {
    @ObservedObject var store: CatalogStore
    @State private var draft: CatalogProject
    var onDelete: () -> Void

    init(store: CatalogStore, project: CatalogProject, onDelete: @escaping () -> Void) {
        self.store = store; _draft = State(initialValue: project); self.onDelete = onDelete
    }
    private func commit() { store.update(draft) }

    private var dollars: Binding<String> {
        Binding(get: { draft.valueCents.map { String(format: "%.2f", Double($0) / 100) } ?? "" },
                set: { draft.valueCents = Double($0).map { Int(($0 * 100).rounded()) } })
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $draft.name).onSubmit(commit)
                // A project sits under an org OR under a parent project. A root
                // project (no parent) must belong to an organisation.
                LabeledContent("Parent project") {
                    OrgProjectTreePicker(
                        store: store,
                        kind: .constant(draft.parentID == nil ? "" : "project"),
                        id: Binding(get: { draft.parentID ?? "" },
                                    set: { newParent in
                                        if newParent.isEmpty {
                                            draft.parentID = nil
                                            if draft.orgID == nil { draft.orgID = store.orgsSorted.first?.id }
                                        } else {
                                            draft.parentID = newParent
                                            draft.orgID = nil   // org inherited from the parent
                                        }
                                        commit()
                                    }),
                        allLabel: "None (top level)", allIcon: "arrow.up.to.line.compact",
                        scope: .projectsOnly, excluding: store.projectSubtree(of: draft.id))
                }
                if draft.parentID == nil {
                    if store.orgsSorted.isEmpty {
                        LabeledContent("Organisation", value: "Add an organisation first")
                    } else {
                        // No "None" — a root project is always filed under an org.
                        LabeledContent("Organisation") {
                            OrgProjectTreePicker(
                                store: store,
                                kind: .constant(draft.orgID == nil ? "" : "org"),
                                id: Binding(get: { draft.orgID ?? "" },
                                            set: { draft.orgID = $0.isEmpty ? nil : $0; commit() }),
                                allLabel: nil, scope: .orgsOnly, placeholder: "Choose org…")
                        }
                    }
                } else {
                    LabeledContent("Organisation", value: store.org(forProject: draft.id).map { store.orgPath(of: $0.id) } ?? "—")
                }
                Picker("Stage", selection: Binding(get: { draft.stage }, set: { draft.stage = $0; commit() })) {
                    ForEach(OppStage.allCases) { Text($0.label).tag($0) }
                }
                TextField("Value (\(draft.currency))", text: dollars).onSubmit(commit)
                Toggle("Archived", isOn: Binding(get: { draft.archived }, set: { draft.archived = $0; commit() }))
            }
            let subs = store.childProjects(of: draft.id)
            if !subs.isEmpty {
                Section("Sub-projects") { ForEach(subs) { p in HStack { Text(p.name); Spacer(); StageBadge(p.stage) } } }
            }
            let notes = store.notes(forProject: draft.id)
            if !notes.isEmpty {
                Section("Relationship") { RelationshipSummaryButton(store: store, entityName: draft.name, notes: notes) }
                Section("Timeline") { RelationshipTimeline(notes: notes) }
            }
            Section { Button("Delete Project", role: .destructive) { store.deleteProject(draft.id); onDelete() } }
        }
        .formStyle(.grouped)
        .navigationTitle(draft.name.isEmpty ? "Project" : draft.name)
        // Repair a legacy orphan root project: give it an org on open.
        .onAppear {
            if draft.parentID == nil, draft.orgID == nil, let first = store.orgsSorted.first?.id {
                draft.orgID = first; commit()
            }
        }
        .onDisappear(perform: commit)
    }
}

// MARK: Tag editor

private struct TagEditor: View {
    @ObservedObject var store: CatalogStore
    @State private var draft: CatalogTag
    var onDelete: () -> Void
    @State private var mergeTarget = ""

    init(store: CatalogStore, tag: CatalogTag, onDelete: @escaping () -> Void) {
        self.store = store; _draft = State(initialValue: tag); self.onDelete = onDelete
    }
    private func commit() { store.update(draft) }

    private var aliasText: Binding<String> {
        Binding(get: { draft.aliases.joined(separator: ", ") }, set: { draft.aliases = splitList($0) })
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $draft.name).onSubmit(commit)
                TextField("Aliases (comma-separated)", text: aliasText).onSubmit(commit)
            }
            let notes = store.notes(forTag: draft.id)
            if !notes.isEmpty { Section("Linked notes") { ForEach(notes) { NoteRow(note: $0) } } }
            Section("Merge") {
                Picker("Merge into", selection: $mergeTarget) {
                    Text("Choose…").tag("")
                    ForEach(store.tagsSorted.filter { $0.id != draft.id }) { Text($0.name).tag($0.id) }
                }
                Button("Merge") { store.mergeTag(draft.id, into: mergeTarget); onDelete() }.disabled(mergeTarget.isEmpty)
            }
            Section { Button("Delete Tag", role: .destructive) { store.deleteTag(draft.id); onDelete() } }
        }
        .formStyle(.grouped)
        .navigationTitle(draft.name.isEmpty ? "Tag" : draft.name)
        .onDisappear(perform: commit)
    }
}

// MARK: Notes list (filterable)

private struct NotesList: View {
    @ObservedObject var store: CatalogStore
    @Binding var selID: String?
    let query: String
    let scope: NoteSearchScope
    let fOrg: String, fProject: String, fTag: String, fPerson: String
    var unassignedOnly: Bool = false
    var missingOnly: Bool = false
    var range: DateRange = .all
    @State private var semanticOrder: [String] = []
    @State private var hovered: String?
    @State private var pendingTrash: CatalogNote?
    @State private var pendingDictation: CatalogNote?
    @State private var trashError: String?
    @State private var dropTargeted = false
    // Which Year/Month/Day groups are open (browse mode only).
    @State private var expanded: Set<String> = []
    // Bulk multi-select.
    @State private var selecting = false
    @State private var multiSel = Set<String>()
    @State private var pendingBulkTrash = false
    @State private var showBulkAssign = false

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }

    /// A live search collapses the date grouping to a flat, rank-ordered list;
    /// browsing (no query) shows the collapsible Year → Month → Day tree.
    private var searching: Bool { !trimmedQuery.isEmpty }

    private func facetFiltered(_ notes: [CatalogNote]) -> [CatalogNote] {
        var ns = notes
        if !fOrg.isEmpty { ns = ns.filter { store.effectiveOrgIDs(of: $0).contains(fOrg) } }
        if !fProject.isEmpty { ns = ns.filter { store.effectiveProjectIDs(of: $0).contains(fProject) } }
        if !fTag.isEmpty { ns = ns.filter { $0.tagIDs.contains(fTag) } }
        if !fPerson.isEmpty { ns = ns.filter { $0.personIDs.contains(fPerson) } }
        if unassignedOnly { ns = ns.filter(store.isUnassigned) }
        if missingOnly { ns = ns.filter { !store.fileExists($0) } }
        // Time window (undated notes drop out while a window is active).
        ns = ns.filter { range.includes($0.date) }
        return ns
    }

    private var filtered: [CatalogNote] {
        if scope == .meaning && searching {
            let rank = Dictionary(uniqueKeysWithValues: semanticOrder.enumerated().map { ($0.element, $0.offset) })
            let base = store.doc.notes.filter { rank[$0.id] != nil }
                .sorted { (rank[$0.id] ?? 0) < (rank[$1.id] ?? 0) }
            return facetFiltered(base)
        }
        var ns = store.doc.notes
        if searching { ns = ns.filter { store.noteMatches($0, query: trimmedQuery) } }
        return facetFiltered(ns).sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    private var groups: [DateGroupNode<CatalogNote>] {
        DateGrouping.tree(filtered) { $0.date }
    }

    var body: some View {
        Group {
            if store.doc.notes.isEmpty {
                ContentUnavailableView {
                    Label("No notes yet", systemImage: "doc.text")
                } description: {
                    Text("Use “Import notes” to add meeting notes.")
                }
            } else {
                VStack(spacing: 0) {
                    HStack {
                        Button {
                            selecting.toggle(); multiSel.removeAll()
                        } label: {
                            Label("Select", systemImage: selecting ? "checkmark.circle.fill" : "checkmark.circle")
                        }
                        .buttonStyle(.borderless).font(.caption)
                        .help("Select multiple to assign or delete")
                        Spacer()
                        if !searching && !filtered.isEmpty {
                            ExpandCollapseButton(tree: groups, expanded: $expanded)
                                .buttonStyle(.borderless).font(.caption)
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    Group {
                        if selecting {
                            List(selection: $multiSel) { noteListContent }
                        } else {
                            List(selection: $selID) { noteListContent }
                        }
                    }
                    if selecting { bulkBar }
                }
                .overlay { if filtered.isEmpty { ContentUnavailableView.search } }
                // Seed the open groups (newest year/month) once results arrive.
                .onChange(of: groups.map(\.id)) { _, _ in
                    if expanded.isEmpty { expanded = DateGrouping.defaultExpanded(groups) }
                }
                .onAppear { if expanded.isEmpty { expanded = DateGrouping.defaultExpanded(groups) } }
            }
        }
        .task(id: "\(scope)|\(trimmedQuery)") { await runSemantic() }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in handleDrop(providers) }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .background(Color.accentColor.opacity(0.06))
                    .overlay(Label("Drop audio to transcribe", systemImage: "waveform.badge.plus")
                        .font(.headline).foregroundStyle(.secondary))
                    .allowsHitTesting(false)
            }
        }
        .confirmationDialog(
            "Move this note to Dictation?",
            isPresented: Binding(get: { pendingDictation != nil }, set: { if !$0 { pendingDictation = nil } }),
            presenting: pendingDictation
        ) { n in
            Button("Move to Dictation") {
                if selID == n.id { selID = nil }
                do {
                    try store.moveNoteToDictation(n.id)
                } catch {
                    trashError = error.localizedDescription
                }
                pendingDictation = nil
            }
            Button("Cancel", role: .cancel) { pendingDictation = nil }
        } message: { n in
            Text("“\(n.title)” will be saved to the dictation archive and removed from the Catalog. Its meeting summary (if any) is not carried over.")
        }
        .confirmationDialog(
            "Move this note to the Trash?",
            isPresented: Binding(get: { pendingTrash != nil }, set: { if !$0 { pendingTrash = nil } }),
            presenting: pendingTrash
        ) { n in
            Button("Move to Trash", role: .destructive) {
                if selID == n.id { selID = nil }
                do {
                    try store.trashNote(n.id)
                } catch {
                    trashError = error.localizedDescription
                }
                pendingTrash = nil
            }
            Button("Cancel", role: .cancel) { pendingTrash = nil }
        } message: { n in
            Text("“\(n.title)” will be moved to the Trash and removed from the Catalog. You can recover it from the Trash.")
        }
        .alert("Couldn't delete the note", isPresented: Binding(get: { trashError != nil }, set: { if !$0 { trashError = nil } })) {
            Button("OK", role: .cancel) { trashError = nil }
        } message: {
            Text(trashError ?? "")
        }
        .confirmationDialog(
            "Move \(multiSel.count) note\(multiSel.count == 1 ? "" : "s") to the Trash?",
            isPresented: $pendingBulkTrash
        ) {
            Button("Move to Trash", role: .destructive) {
                let ids = Array(multiSel)
                if let sel = selID, multiSel.contains(sel) { selID = nil }
                _ = store.trashNotes(ids)
                multiSel.removeAll()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The Markdown files move to the Trash and their Catalog rows are removed. You can recover the files from the Trash.")
        }
        .sheet(isPresented: $showBulkAssign) {
            BulkAssignSheet(store: store, noteIDs: Array(multiSel))
        }
    }

    /// The list rows, shared by the single- and multi-select list variants.
    @ViewBuilder private var noteListContent: some View {
        if searching {
            ForEach(filtered) { noteRow($0) }
        } else {
            DateGroupDisclosure(nodes: groups, expanded: $expanded) { noteRow($0) }
        }
    }

    /// Bulk action bar shown while selecting multiple notes.
    private var bulkBar: some View {
        let ids = Array(multiSel)
        return VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                Text(ids.isEmpty ? "Select notes" : "\(ids.count) selected")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button { showBulkAssign = true } label: { Label("Assign…", systemImage: "tag") }
                    .disabled(ids.isEmpty)
                Button(role: .destructive) { pendingBulkTrash = true } label: {
                    Label("Trash", systemImage: "trash")
                }.disabled(ids.isEmpty)
                Button("Done") { selecting = false; multiSel.removeAll() }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .background(.bar)
    }


    /// A single note row — title, badges, date/tags, and hover/context actions.
    /// Tagged with the note id so it participates in the List's selection whether
    /// it sits in a flat search result or nested inside a date group.
    @ViewBuilder private func noteRow(_ n: CatalogNote) -> some View {
        let missing = !store.fileExists(n)
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(n.title).lineLimit(1).foregroundStyle(missing ? .secondary : .primary)
                    if missing {
                        CapsulePill(text: "File missing", color: .red)
                    } else if store.isUnassigned(n) {
                        CapsulePill(text: "Unassigned", color: .orange)
                    }
                }
                HStack(spacing: 6) {
                    if let d = n.date { Text(d.formatted(date: .abbreviated, time: .shortened)) }
                    if !n.tagIDs.isEmpty { Text("· \(n.tagIDs.count) tags") }
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            // Row actions — always shown for missing rows (they need triage),
            // otherwise revealed on hover to keep it clean.
            if hovered == n.id || missing {
                if !missing {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([store.url(of: n)])
                    } label: { Image(systemName: "folder") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .help("Reveal in Finder")
                }
                if missing {
                    // File is already gone — the only action is to drop the stale row.
                    Button {
                        if selID == n.id { selID = nil }
                        store.deleteNote(n.id)
                    } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).foregroundStyle(.red)
                    .help("Remove this missing entry from the catalog")
                } else {
                    Menu {
                        Button("Remove from Catalog (keep file)") {
                            if selID == n.id { selID = nil }
                            store.deleteNote(n.id)
                        }
                        Button("Move Note to Trash…", role: .destructive) {
                            pendingTrash = n
                        }
                    } label: { Image(systemName: "trash") }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .foregroundStyle(.secondary)
                    .help("Remove from catalog, or move the note file to Trash")
                }
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onHover { hovered = $0 ? n.id : (hovered == n.id ? nil : hovered) }
        .contextMenu {
            if !missing {
                Button("Open") { selID = n.id }
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([store.url(of: n)])
                }
                Divider()
                Button("Move to Dictation…") { pendingDictation = n }
            }
            Button("Remove from Catalog") {
                if selID == n.id { selID = nil }
                store.deleteNote(n.id)
            }
            if !missing {
                Button("Move to Trash…", role: .destructive) { pendingTrash = n }
            }
        }
        .tag(n.id)
    }


    /// Accept dropped audio files → hand them to the importer, which transcribes
    /// each into a meeting note and adds a Catalog row. Non-audio drops are
    /// ignored (returns false so the system shows the "no" cursor).
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return false }
        var urls: [URL] = []
        let group = DispatchGroup()
        for p in fileProviders {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                DispatchQueue.main.async {
                    if let url, AudioFileImporter.isAccepted(url) { urls.append(url) }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) {
            guard !urls.isEmpty else { return }
            (NSApp.delegate as? AppDelegate)?.showAudioImport(urls: urls)
        }
        return true
    }

    private func runSemantic() async {
        guard scope == .meaning, !trimmedQuery.isEmpty else { semanticOrder = []; return }
        let hits = await NotesLibrary.semanticSearch(trimmedQuery)
        let byPath = Dictionary(store.doc.notes.map { (store.url(of: $0).path, $0.id) }, uniquingKeysWith: { a, _ in a })
        semanticOrder = hits.compactMap { byPath[$0.file.url.path] }
    }
}

private enum NoteSearchScope: Hashable { case text, meaning, ask }

/// Filter-scoped Ask: retrieves excerpts from the currently-filtered notes,
/// answers with the polishing model, and cites the source notes.
private struct NoteAskView: View {
    @ObservedObject var store: CatalogStore
    let question: String
    let nonce: Int
    let files: [NotesLibrary.MeetingFile]
    let filterSummary: String
    var onPickNote: (String) -> Void

    @State private var answer = ""
    @State private var sources: [NotesLibrary.MeetingFile] = []
    @State private var isAsking = false
    @State private var errorMessage: String?
    private let polisher = TextPolisher()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Label("Asking across: \(filterSummary)", systemImage: "line.3.horizontal.decrease.circle")
                    .font(.caption).foregroundStyle(.secondary)

                if isAsking {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Thinking…").foregroundStyle(.secondary) }
                } else if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                } else if !answer.isEmpty {
                    Text(question).font(.headline)
                    Text(answer).textSelection(.enabled)
                    if !sources.isEmpty {
                        Divider()
                        Text("Sources").font(.caption).foregroundStyle(.secondary)
                        ForEach(sources) { f in
                            if let note = store.doc.notes.first(where: { store.url(of: $0).path == f.url.path }) {
                                Button { onPickNote(note.id) } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: "doc.text").foregroundStyle(.secondary)
                                        Text(note.title).lineLimit(1)
                                        Spacer()
                                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                                    }
                                }.buttonStyle(.plain)
                            } else {
                                Button { NotesViewerWindowController.present(fileURL: f.url) } label: {
                                    Label(f.displayName, systemImage: "doc.text")
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                } else {
                    ContentUnavailableView("Ask about these notes",
                        systemImage: "sparkles",
                        description: Text("Type a question in the search field and press Return. Answers are drawn only from the filtered notes, with cited sources."))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .task(id: nonce) { if nonce > 0 { await run() } }
    }

    private func run() async {
        let q = question.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        isAsking = true; errorMessage = nil; answer = ""; sources = []
        guard !files.isEmpty else {
            answer = "No notes match the current filters."; isAsking = false; return
        }
        do {
            let retrieved = NotesLibrary.semanticAvailable
                ? await NotesLibrary.semanticExcerpts(for: q, files: files)
                : fallbackExcerpts()
            if retrieved.text.isEmpty {
                answer = "Nothing in these notes matched the question. Try rewording or widening the filters."
            } else {
                answer = try await polisher.answerAcrossMeetings(question: q, excerpts: retrieved.text)
                sources = retrieved.sources
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isAsking = false
    }

    /// When no on-device embedding model exists, just feed the filtered notes'
    /// text (capped) so Ask still works — scoped to the same files.
    private func fallbackExcerpts() -> NotesLibrary.ExcerptResult {
        var out = "", used: [NotesLibrary.MeetingFile] = []
        for f in files {
            guard let body = f.url.readText() else { continue }
            let block = "\n=== Meeting \(f.displayName) ===\n\(body)\n"
            if out.count + block.count > 20_000 { break }
            out += block; used.append(f)
        }
        return NotesLibrary.ExcerptResult(text: out, sources: used)
    }
}

// MARK: Note editor — chip-based assignment

private struct NoteLinkEditor: View {
    @ObservedObject var store: CatalogStore
    let note: CatalogNote
    @State private var showAssign = false

    private var current: CatalogNote { store.note(id: note.id) ?? note }

    /// People grouped under the type hierarchy for the Add-person picker,
    /// excluding those already on the note. Type headers with no addable people
    /// are omitted so the tree stays tight.
    private func peoplePickRows(excluding taken: [String]) -> [ChipPickRow] {
        let takenSet = Set(taken)
        var rows: [ChipPickRow] = []
        func emit(_ type: CatalogPersonType, _ depth: Int) {
            let avail = store.people(ofType: type.id).filter { !takenSet.contains($0.id) }
            let kids = store.childPersonTypes(of: type.id)
            // Skip a header only if neither it nor its descendants add anything.
            let before = rows.count
            rows.append(ChipPickRow(id: "type:\(type.id)", name: type.name, depth: depth, isHeader: true))
            for p in avail { rows.append(ChipPickRow(id: p.id, name: p.name, depth: depth + 1)) }
            for c in kids { emit(c, depth + 1) }
            if rows.count == before + 1 { rows.removeLast() }   // header added nothing
        }
        for root in store.rootPersonTypes { emit(root, 0) }
        let untyped = store.people(ofType: nil).filter { !takenSet.contains($0.id) }
        if !untyped.isEmpty {
            rows.append(ChipPickRow(id: "type:none", name: "No type", isHeader: true))
            for p in untyped { rows.append(ChipPickRow(id: p.id, name: p.name, depth: 1)) }
        }
        return rows
    }

    var body: some View {
        Form {
            Section {
                Button { openNote(note) } label: { Label("Open note", systemImage: "arrow.up.forward.app") }
                if let d = note.date { LabeledContent("Date") { Text(d.formatted(date: .abbreviated, time: .shortened)) } }
            }

            // Single "Filed under": the note's project OR org, as removable
            // chips. One Assign… control handles both (mutually exclusive).
            Section("Filed under") {
                let projs = store.doc.projects.filter { current.projectIDs.contains($0.id) }
                let orgsDirect = store.orgsSorted.filter { current.orgIDs.contains($0.id) }
                if projs.isEmpty && orgsDirect.isEmpty {
                    Text("Unassigned").font(.caption).foregroundStyle(.secondary)
                } else {
                    FlowChips {
                        ForEach(projs) { p in
                            Chip(text: store.projectPath(of: p.id), color: .teal) { store.setProject(p.id, on: note.id, false) }
                        }
                        ForEach(orgsDirect) { o in
                            Chip(text: store.orgPath(of: o.id), color: .blue) { store.setOrg(o.id, on: note.id, false) }
                        }
                    }
                }
                Button { showAssign = true } label: { Label("Assign…", systemImage: "plus.circle") }
                    .buttonStyle(.plain).foregroundStyle(.tint).font(.callout)
                    .popover(isPresented: $showAssign) {
                        AssignPopover(store: store, noteID: note.id, show: $showAssign)
                    }
                // Inherited context (read-only): the org resolved up the
                // project hierarchy, when not directly assigned.
                let viaProject = store.effectiveOrgIDs(of: current).subtracting(current.orgIDs)
                if !viaProject.isEmpty {
                    Text("Org via project: " + store.orgsSorted.filter { viaProject.contains($0.id) }
                        .map { store.orgPath(of: $0.id) }.joined(separator: ", "))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }

            Section("People") {
                let selected = store.doc.people.filter { current.personIDs.contains($0.id) }.sortedByName
                if selected.isEmpty {
                    Text("None").font(.caption).foregroundStyle(.secondary)
                } else {
                    FlowChips {
                        ForEach(selected) { p in
                            Chip(text: p.name, color: .teal) { store.setPerson(p.id, on: note.id, false) }
                        }
                    }
                }
                AddChipButton(
                    title: "Add person…", placeholder: "Search people",
                    options: store.doc.people.sortedByName
                        .filter { !current.personIDs.contains($0.id) }.map { ($0.id, $0.name) },
                    hierarchy: peoplePickRows(excluding: current.personIDs),
                    onPick: { store.setPerson($0, on: note.id, true) },
                    onCreate: { store.setPerson(store.addPerson(name: $0).id, on: note.id, true) })
            }

            Section("Tags") {
                let selected = store.tagsSorted.filter { current.tagIDs.contains($0.id) }
                if selected.isEmpty {
                    Text("None").font(.caption).foregroundStyle(.secondary)
                } else {
                    FlowChips {
                        ForEach(selected) { t in
                            Chip(text: "#\(t.name)", color: .pink) { store.setTag(t.id, on: note.id, false) }
                        }
                    }
                }
                AddChipButton(
                    title: "Add tag…", placeholder: "Search tags",
                    options: store.tagsSorted
                        .filter { !current.tagIDs.contains($0.id) }.map { ($0.id, $0.name) },
                    onPick: { store.setTag($0, on: note.id, true) },
                    onCreate: { store.setTag(store.addTag(name: $0).id, on: note.id, true) })
            }

            // Words the note's own front-matter suggests — each can become any
            // entity type (they route differently), so this is its own section.
            let suggestions = store.suggestedTags(for: current)
            if !suggestions.isEmpty {
                Section {
                    FlowChips {
                        ForEach(suggestions, id: \.self) { token in
                            PromoteMenu(store: store, noteID: note.id, token: token, asChip: true) {}
                        }
                    }
                } header: {
                    Text("From this note")
                } footer: {
                    Text("Words pulled from the note — tap one to add it as a tag, person, project, or organisation.")
                        .font(.caption2)
                }
            }

            NoteActionItemsSection(url: store.url(of: current))
        }
        .formStyle(.grouped)
        .navigationTitle(note.title)
    }
}

// MARK: Chip-editor building blocks

/// A pill showing a selected value with a remove (✕) button.
private struct Chip: View {
    let text: String
    var color: Color = .blue
    var onRemove: () -> Void
    var body: some View {
        HStack(spacing: 4) {
            Text(text).font(.caption).lineLimit(1)
            Button(action: onRemove) { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                .buttonStyle(.plain)
        }
        .foregroundStyle(color)
        .pillBackground(color, opacity: 0.16, hPad: 8, vPad: 3)
    }
}

/// Simple wrapping layout for chips.
private struct FlowChips<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { FlowLayout(spacing: 6) { content } }
}

/// A "+ add…" button that opens a searchable picker of existing options, with a
/// "Create …" row when the query matches nothing.
/// One row of a hierarchical `AddChipButton` picker — either a non-selectable
/// grouping header (e.g. a person type) or a pickable option, indented by depth.
struct ChipPickRow: Identifiable {
    let id: String
    let name: String
    var depth: Int = 0
    var isHeader: Bool = false
}

private struct AddChipButton: View {
    let title: String
    let placeholder: String
    let options: [(id: String, name: String)]
    /// Optional grouped/indented rows shown while the search box is empty
    /// (e.g. people under their type). Searching falls back to the flat
    /// `options` match list. Headers are skipped from selection.
    var hierarchy: [ChipPickRow]? = nil
    let onPick: (String) -> Void
    let onCreate: (String) -> Void
    @State private var show = false
    @State private var query = ""

    var body: some View {
        Button { show = true } label: { Label(title, systemImage: "plus.circle").font(.callout) }
            .buttonStyle(.plain).foregroundStyle(.tint)
            .popover(isPresented: $show) {
                let q = query.trimmingCharacters(in: .whitespaces)
                let matches = options.filter { q.isEmpty || $0.name.localizedCaseInsensitiveContains(q) }
                let exact = options.contains { $0.name.caseInsensitiveCompare(q) == .orderedSame }
                let showTree = q.isEmpty && (hierarchy?.isEmpty == false)
                VStack(spacing: 6) {
                    EntitySearchBar(text: $query, placeholder: placeholder)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            // Picking does NOT dismiss — the chosen item drops out
                            // of the options (recomputed by the parent) so you can
                            // add several in a row. Click away to close.
                            if showTree {
                                ForEach(hierarchy!) { row in
                                    if row.isHeader {
                                        Text(row.name).font(.caption.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                            .padding(.leading, CGFloat(row.depth) * 12).padding(.top, 3)
                                    } else {
                                        Button { onPick(row.id); query = "" } label: {
                                            HStack { Text(row.name); Spacer(); Image(systemName: "plus") }
                                                .contentShape(Rectangle())
                                        }.buttonStyle(.plain)
                                        .padding(.leading, CGFloat(row.depth) * 12)
                                    }
                                }
                            } else {
                                ForEach(matches, id: \.id) { opt in
                                    Button { onPick(opt.id); query = "" } label: {
                                        HStack { Text(opt.name); Spacer(); Image(systemName: "plus") }
                                            .contentShape(Rectangle())
                                    }.buttonStyle(.plain)
                                }
                            }
                            if !q.isEmpty && !exact {
                                Button { onCreate(q); query = "" } label: {
                                    Label("Create “\(q)”", systemImage: "plus.circle.fill")
                                }.buttonStyle(.plain).foregroundStyle(.tint)
                            }
                            if matches.isEmpty && q.isEmpty {
                                Text("Nothing left to add").font(.caption).foregroundStyle(.secondary)
                            }
                            if matches.isEmpty && !q.isEmpty && exact {
                                Text("Already added").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 4)
                    }
                    .frame(maxHeight: 220)
                }
                .padding(10).frame(width: 250)
            }
    }
}

/// The Assign… picker: choose a project OR an organisation (mutually
/// exclusive). Assigning clears the other side via the store helpers.
private struct AssignPopover: View {
    @ObservedObject var store: CatalogStore
    let noteID: String
    @Binding var show: Bool
    @State private var query = ""

    var body: some View {
        VStack(spacing: 8) {
            EntitySearchBar(text: $query, placeholder: "Search organisations & projects")
            let rows = store.orgProjectRows(matching: query)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if rows.isEmpty {
                        Text("No organisations or projects").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(rows) { r in
                        Button {
                            if r.kind == "org" { store.setOrg(r.id, on: noteID, true) }
                            else { store.setProject(r.id, on: noteID, true) }
                            show = false
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: r.kind == "org" ? "building.2" : "folder")
                                    .font(.caption2).foregroundStyle(.secondary).frame(width: 14)
                                Text(r.name).lineLimit(1)
                                Spacer()
                            }
                            .padding(.leading, CGFloat(r.depth) * 14)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 4)
            }
            .frame(maxHeight: 260)
        }
        .padding(10).frame(width: 300)
    }

}

/// Action items parsed from the note file, with tick + export-to-Reminders,
/// mirroring the Catalog. Scrolls when there are many.
private struct NoteActionItemsSection: View {
    let url: URL
    @State private var items: [NotesLibrary.ActionItem] = []
    @State private var message = ""

    var body: some View {
        Section {
            if items.isEmpty {
                Text("No action items in this note.").font(.caption).foregroundStyle(.secondary)
            } else {
                // All items shown (the form scrolls) so none are hidden.
                ForEach(items) { item in
                    HStack(spacing: 8) {
                        Button { toggle(item) } label: {
                            Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(item.done ? Color.green : Color.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.displayText).strikethrough(item.done)
                            HStack(spacing: 6) {
                                if let owner = item.owner { Text("@\(owner)") }
                                if let due = item.due { Text("due \(due)") }
                            }.font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { export([item]) } label: { Image(systemName: "bell.badge") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .help("Export to Reminders")
                    }
                }
            }
        } header: {
            HStack {
                Text("Action items")
                Spacer()
                if !items.isEmpty {
                    Button("Export all to Reminders") { export(items) }.font(.caption)
                }
            }
        } footer: {
            if !message.isEmpty { Text(message).font(.caption2).foregroundStyle(.secondary) }
        }
        .onAppear(perform: load)
    }

    private func load() { items = NotesLibrary.actionItems(inFile: url) }
    private func toggle(_ item: NotesLibrary.ActionItem) { _ = NotesLibrary.toggleDone(item); load() }
    private func export(_ list: [NotesLibrary.ActionItem]) {
        Task { @MainActor in
            do { let n = try await RemindersExporter.export(list); message = "Exported \(n) to Reminders" }
            catch { message = "Export failed: \(error.localizedDescription)" }
        }
    }
}

/// "Add as ▾" menu that turns a token into any catalog entity and wires it into
/// the note's hierarchy (people attach to the note; a project files the note under it).
private struct PromoteMenu: View {
    @ObservedObject var store: CatalogStore
    let noteID: String
    let token: String
    var asChip = false
    var onDone: () -> Void

    private var note: CatalogNote? { store.note(id: noteID) }

    var body: some View {
        Menu {
            // Assigned to the note:
            Button { let t = store.addTag(name: token); store.setTag(t.id, on: noteID, true); onDone() }
                label: { Label("Tag", systemImage: "tag") }
            Button(action: addPerson) { Label("Person", systemImage: "person") }
            Button(action: addProject) { Label("Project", systemImage: "folder") }
            Divider()
            // Created only — assign it yourself:
            Button { _ = store.addOrg(name: token); onDone() }
                label: { Label("Organisation (create only)", systemImage: "building.2") }
        } label: {
            if asChip {
                HStack(spacing: 4) {
                    Text(token).font(.caption).lineLimit(1)
                    Image(systemName: "plus").font(.system(size: 8, weight: .bold))
                }
                .foregroundStyle(.secondary)
                .pillBackground(.secondary, opacity: 0.15, hPad: 8, vPad: 3)
            } else {
                Label("Add as", systemImage: "plus.circle")
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func addPerson() {
        let p = store.addPerson(name: token)
        store.setPerson(p.id, on: noteID, true)   // attach directly to the note, like tags
        onDone()
    }
    private func addProject() {
        // New project inherits the note's current org (if any), then files the note under it.
        let orgID = note.flatMap { store.effectiveOrgIDs(of: $0).first }
        let p = store.addProject(name: token, orgID: orgID)
        store.setProject(p.id, on: noteID, true)
        onDone()
    }
}

// MARK: Map — the whole catalog as one pickable tree

private typealias MapPick = (CatalogSection, String) -> Void

/// Shared, controlled expansion state for the map tree, so Expand/Collapse All
/// and search can drive every node from one place (uncontrolled
/// DisclosureGroups can't be opened programmatically).
final class MapExpansion: ObservableObject {
    @Published var open: Set<String> = []
    func binding(_ id: String) -> Binding<Bool> {
        Binding(get: { self.open.contains(id) },
                set: { if $0 { self.open.insert(id) } else { self.open.remove(id) } })
    }
}

/// Shared scope/range/leaf-visibility rules for the map, passed down every node
/// so the tree prunes consistently. When `range` is "All time" everything shows;
/// otherwise a node is kept only if its subtree holds a note in the window.
@MainActor
private struct MapFilter {
    let store: CatalogStore
    let range: DateRange
    let showPeople: Bool
    let showTags: Bool

    func note(_ n: CatalogNote) -> Bool { range.includes(n.date) }
    func project(_ pid: String) -> Bool {
        if range.days == nil { return true }
        return store.doc.notes.contains { $0.projectIDs.contains(pid) && note($0) }
            || store.childProjects(of: pid).contains { project($0.id) }
    }
    func org(_ oid: String) -> Bool {
        if range.days == nil { return true }
        return store.notes(directlyOnOrg: oid).contains { note($0) }
            || store.rootProjects(forOrg: oid).contains { project($0.id) }
            || store.childOrgs(of: oid).contains { org($0.id) }
    }
}

private struct MapTree: View {
    @ObservedObject var store: CatalogStore
    let onPick: MapPick
    @State private var search = ""
    @State private var scopeKind = ""   // "", "org", "project"
    @State private var scopeID = ""
    @State private var range: DateRange = .all
    @State private var showPeople = true
    @State private var showTags = true
    @StateObject private var exp = MapExpansion()

    private var q: String { search.trimmingCharacters(in: .whitespaces).lowercased() }
    private var filter: MapFilter {
        MapFilter(store: store, range: range, showPeople: showPeople, showTags: showTags)
    }
    private var mapNonDefault: Bool {
        !q.isEmpty || !scopeID.isEmpty || range != .all || !showPeople || !showTags
    }
    private func resetMap() {
        search = ""; scopeKind = ""; scopeID = ""; range = .all; showPeople = true; showTags = true
    }

    /// Every container node's id — used to expand the whole tree at once.
    private var allNodeIDs: Set<String> {
        Set(store.doc.orgs.map(\.id))
            .union(store.doc.projects.map(\.id))
            .union(store.doc.notes.map { "note:" + $0.id })
            .union(store.doc.notes.map { "note-people:" + $0.id })
            .union(store.doc.notes.map { "note-tags:" + $0.id })
    }

    /// An org matches if its own name — or any descendant org's name — contains
    /// the query, so nested orgs stay findable and the tree structure is kept.
    private func matches(_ org: CatalogOrg) -> Bool {
        if q.isEmpty { return true }
        return store.orgSubtree(of: org.id).contains { id in
            store.org(id)?.name.lowercased().contains(q) ?? false
        }
    }

    /// The root nodes to render, honoring the account/project scope. Scoping to
    /// an org (or project) re-roots the tree at that node.
    private var scopedRootOrgs: [CatalogOrg] {
        if scopeKind == "org", let o = store.org(scopeID) { return [o] }
        if scopeKind == "project" { return [] }
        return store.rootOrgs
    }
    private var rootOrgs: [CatalogOrg] {
        scopedRootOrgs.filter(matches).filter { filter.org($0.id) }
    }
    private var scopedProject: CatalogProject? {
        scopeKind == "project" ? store.project(scopeID) : nil
    }
    /// Only TRUE orphans belong in the "No organisation" section: a project with
    /// no parent AND no (resolvable) org. Sub-projects have `orgID == nil` by
    /// design — they inherit the org through their parent — so they must NOT be
    /// listed here; they render nested under their parent instead.
    private var orphanProjects: [CatalogProject] {
        guard scopeKind == "" else { return [] }
        return store.doc.projects.sortedByName
            .filter { $0.parentID == nil && store.org(forProject: $0.id) == nil }
            .filter { q.isEmpty || $0.name.lowercased().contains(q) }
            .filter { filter.project($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                EntitySearchBar(text: $search, placeholder: "Filter organisations")
                Button { exp.open = allNodeIDs } label: { Image(systemName: "chevron.down.square") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Expand all")
                    .disabled(exp.open.count == allNodeIDs.count)
                Button { exp.open = [] } label: { Image(systemName: "chevron.right.square") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Collapse all")
                    .disabled(exp.open.isEmpty)
            }
            .padding(.horizontal, 10).padding(.top, 6)
            HStack(spacing: 6) {
                OrgProjectTreePicker(store: store, kind: $scopeKind, id: $scopeID,
                                     allLabel: "Whole catalog")
                RangePicker(range: $range, compact: true)
                Spacer(minLength: 0)
                Menu {
                    Toggle("Show people", isOn: $showPeople)
                    Toggle("Show tags", isOn: $showTags)
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Show or hide People and Tags leaves")
                if mapNonDefault {
                    ResetButton(help: "Reset search, scope, range & visibility", action: resetMap)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            Divider()
            List {
                if store.doc.orgs.isEmpty && store.doc.projects.isEmpty {
                    Text("Nothing to map yet — add organisations, or import notes.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(rootOrgs) { OrgMapNode(store: store, org: $0, exp: exp, filter: filter, onPick: onPick) }
                if let p = scopedProject {
                    ProjectMapNode(store: store, project: p, exp: exp, filter: filter, onPick: onPick)
                }
                if !orphanProjects.isEmpty {
                    Section("No organisation") {
                        ForEach(orphanProjects) { ProjectMapNode(store: store, project: $0, exp: exp, filter: filter, onPick: onPick) }
                    }
                }
            }
        }
        // While filtering, open everything so matches deep in the tree are shown;
        // restore to a collapsed tree when the filter is cleared.
        .onChange(of: q) { _, new in exp.open = new.isEmpty ? [] : allNodeIDs }
    }
}

/// A tappable node label with a trailing "jump to" affordance.
private struct MapRow: View {
    let icon: String, tint: Color, title: String
    var subtitle: String? = nil
    var trailing: AnyView? = nil
    var openIcon: String = "arrow.right.circle"
    let pick: () -> Void
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon).foregroundStyle(tint).frame(width: 16)
            Text(title).lineLimit(1)
            if let subtitle { Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
            Spacer(minLength: 6)
            if let trailing { trailing }
            Button(action: pick) { Image(systemName: openIcon) }
                .buttonStyle(.plain).foregroundStyle(.tertiary)
                .help("Open")
        }
    }
}

private struct OrgMapNode: View {
    @ObservedObject var store: CatalogStore
    let org: CatalogOrg
    @ObservedObject var exp: MapExpansion
    let filter: MapFilter
    let onPick: MapPick
    var body: some View {
        DisclosureGroup(isExpanded: exp.binding(org.id)) {
            ForEach(store.childOrgs(of: org.id).filter { filter.org($0.id) }) {
                OrgMapNode(store: store, org: $0, exp: exp, filter: filter, onPick: onPick)
            }
            // Only this org's TOP-LEVEL projects hang off it directly; sub-projects
            // appear nested under their parent (inheriting the org through it), so
            // the tree stays a true hierarchy with no duplicates.
            ForEach(store.rootProjects(forOrg: org.id).filter { filter.project($0.id) }) {
                ProjectMapNode(store: store, project: $0, exp: exp, filter: filter, onPick: onPick)
            }
            // Internal notes attached directly to this org (no project).
            ForEach(store.notes(directlyOnOrg: org.id).filter(filter.note).sortedByDateDescending) {
                NoteMapNode(store: store, note: $0, exp: exp, filter: filter, onPick: onPick)
            }
        } label: {
            MapRow(icon: "building.2", tint: .blue, title: org.name,
                   trailing: AnyView(RelationshipBadge(org.relationship))) { onPick(.organisations, org.id) }
        }
    }
}

private struct ProjectMapNode: View {
    @ObservedObject var store: CatalogStore
    let project: CatalogProject
    @ObservedObject var exp: MapExpansion
    let filter: MapFilter
    let onPick: MapPick
    var body: some View {
        DisclosureGroup(isExpanded: exp.binding(project.id)) {
            let subs = store.childProjects(of: project.id).filter { filter.project($0.id) }
            ForEach(subs) { ProjectMapNode(store: store, project: $0, exp: exp, filter: filter, onPick: onPick) }
            let notes = store.doc.notes.filter { $0.projectIDs.contains(project.id) && filter.note($0) }.sortedByDateDescending
            if subs.isEmpty && notes.isEmpty { Text("No notes").font(.caption2).foregroundStyle(.secondary) }
            ForEach(notes) { NoteMapNode(store: store, note: $0, exp: exp, filter: filter, onPick: onPick) }
        } label: {
            MapRow(icon: "folder", tint: .orange, title: project.name,
                   trailing: AnyView(StageBadge(project.stage))) { onPick(.projects, project.id) }
        }
    }
}

/// A note in the map, expandable to its own people and tags. Falls back to a
/// plain row when it has neither, so leaf notes don't show an empty twisty.
private struct NoteMapNode: View {
    @ObservedObject var store: CatalogStore
    let note: CatalogNote
    @ObservedObject var exp: MapExpansion
    let filter: MapFilter
    let onPick: MapPick

    var body: some View {
        let people = filter.showPeople ? store.people(of: note) : []
        let tags = filter.showTags ? store.tags(of: note) : []
        let label = MapRow(icon: "doc.text", tint: .indigo, title: note.title,
                           openIcon: "arrow.up.forward.app") { openNote(note) }
        if people.isEmpty && tags.isEmpty {
            label
        } else {
            DisclosureGroup(isExpanded: exp.binding("note:" + note.id)) {
                if !people.isEmpty {
                    DisclosureGroup(isExpanded: exp.binding("note-people:" + note.id)) {
                        ForEach(people) { p in
                            MapRow(icon: "person", tint: .teal, title: p.name) { onPick(.people, p.id) }
                        }
                    } label: {
                        Label("People (\(people.count))", systemImage: "person.2").font(.callout)
                    }
                }
                if !tags.isEmpty {
                    DisclosureGroup(isExpanded: exp.binding("note-tags:" + note.id)) {
                        ForEach(tags) { t in
                            MapRow(icon: "tag", tint: .pink, title: t.name) { onPick(.tags, t.id) }
                        }
                    } label: {
                        Label("Tags (\(tags.count))", systemImage: "tag").font(.callout)
                    }
                }
            } label: { label }
        }
    }
}

// MARK: - Track sections (Open Questions · POC Tracker)
//
// The Catalog's "Track" group. Open Questions is a cross-meeting inbox pulled
// from each note's `## Unanswered Questions` section. POC criteria hang off a
// Catalog project (`pocCriteria`), so that tracker lives here too: pick a
// project, edit its criteria in the detail pane (which can also seed them from
// the project's linked meetings).

/// A cross-meeting list of every open technical/unanswered question, grouped by
/// account/project → note, with search + an org/project filter. The dashboard
/// card is a 5-item teaser of this. Click a question to open its source note.
private struct OpenQuestionsList: View {
    @ObservedObject var store: CatalogStore
    @State private var items: [QItem] = []
    @State private var loading = false
    @State private var query = ""
    @State private var fKind = ""   // "", "org", "project"
    @State private var fID = ""
    @State private var fRange: DateRange = DateRange.defaultRange
    // Open Year/Month/Day groups.
    @State private var expanded: Set<String> = []
    // Include answered (ticked-off) questions in the list.
    @State private var showAnswered = false

    struct QItem: Identifiable {
        let id = UUID()
        let question: String
        let title: String
        let date: Date?
        let url: URL
        let orgIDs: Set<String>
        let projIDs: Set<String>
        var done: Bool
        var rawLine: String
    }

    // A note and its unanswered questions, inside an account/project group.
    struct NoteGroup: Identifiable {
        let url: URL
        var id: URL { url }
        let title: String
        let date: Date?
        var questions: [QItem]
    }
    private var filtered: [QItem] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return items.filter { item in
            (showAnswered || !item.done)
            && (q.isEmpty || item.question.lowercased().contains(q) || item.title.lowercased().contains(q))
            && (fKind != "org" || item.orgIDs.contains(fID))
            && (fKind != "project" || item.projIDs.contains(fID))
            && fRange.includes(item.date)
        }
    }

    /// Open (not-yet-answered) questions among the currently filtered set.
    private var openCount: Int { filtered.filter { !$0.done }.count }

    /// The filtered questions collapsed into one entry per note (newest-first).
    private var noteGroups: [NoteGroup] {
        var order: [URL] = []
        var byURL: [URL: NoteGroup] = [:]
        for q in filtered {
            if let existing = byURL[q.url] {
                var ng = existing; ng.questions.append(q); byURL[q.url] = ng
            } else {
                byURL[q.url] = NoteGroup(url: q.url, title: q.title, date: q.date, questions: [q])
                order.append(q.url)
            }
        }
        return order.compactMap { byURL[$0] }
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    /// Notes grouped into the shared Year → Month → Day tree.
    private var tree: [DateGroupNode<NoteGroup>] {
        DateGrouping.tree(noteGroups) { $0.date }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                if loading && items.isEmpty {
                    ProgressView("Scanning notes…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if filtered.isEmpty {
                    ContentUnavailableView("No open questions", systemImage: "checkmark.circle",
                        description: Text("Questions collect here from meeting notes that have an “Open Questions” section (enable AI Extraction in Settings → Meetings)."))
                } else {
                    List {
                        DateGroupDisclosure(nodes: tree, expanded: $expanded) { ng in
                            VStack(alignment: .leading, spacing: 2) {
                                noteHeader(ng)
                                ForEach(ng.questions) { q in questionRow(q) }
                            }
                        }
                    }
                    .onChange(of: tree.map(\.id)) { _, _ in
                        if expanded.isEmpty { expanded = DateGrouping.defaultExpanded(tree) }
                    }
                    .onAppear { if expanded.isEmpty { expanded = DateGrouping.defaultExpanded(tree) } }
                }
            }
        }
        .task { await scan() }
    }

    /// A note's row inside a group — click to open the note; shows its date and
    /// how many questions it holds.
    private func noteHeader(_ ng: NoteGroup) -> some View {
        Button { NotesViewerWindowController.present(fileURL: ng.url) } label: {
            HStack(spacing: 6) {
                Image(systemName: "doc.text").font(.caption2).foregroundStyle(.secondary)
                Text(ng.title).font(.subheadline.weight(.medium)).lineLimit(1)
                if let d = ng.date {
                    Text(d.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                let open = ng.questions.filter { !$0.done }.count
                Text(open == ng.questions.count ? "\(open) open" : "\(open) open · \(ng.questions.count - open) answered")
                    .font(.caption2).foregroundStyle(.secondary)
                Image(systemName: "arrow.up.forward.square").font(.caption2).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
    }

    /// A single question, indented under its note. The leading checkbox ticks
    /// it answered (or back to open); tapping the text opens the source note.
    private func questionRow(_ q: QItem) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Button { toggle(q) } label: {
                Image(systemName: q.done ? "checkmark.circle.fill" : "circle")
                    .font(.caption).foregroundStyle(q.done ? .green : .orange).padding(.top, 2)
            }
            .buttonStyle(.plain)
            .help(q.done ? "Mark as unanswered" : "Mark as answered")
            Text(q.question)
                .lineLimit(4)
                .strikethrough(q.done, color: .secondary)
                .foregroundStyle(q.done ? .secondary : .primary)
            Spacer(minLength: 0)
        }
        .padding(.leading, 8)
        .contentShape(Rectangle())
        .onTapGesture { NotesViewerWindowController.present(fileURL: q.url) }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("\(openCount) open").font(.headline)
            Spacer()
            EntitySearchBar(text: $query, placeholder: "Search questions").frame(width: 160)
            Toggle("Answered", isOn: $showAnswered)
                .toggleStyle(.button).font(.caption)
                .help("Show questions already marked answered")
            RangePicker(range: $fRange, compact: true)
            OrgProjectTreePicker(store: store, kind: $fKind, id: $fID, allLabel: "All accounts")
            if !filtered.isEmpty {
                ExpandCollapseButton(tree: tree, expanded: $expanded)
                    .buttonStyle(.borderless).labelStyle(.iconOnly)
            }
            Button { Task { await scan() } } label: { Image(systemName: "arrow.clockwise") }
                .help("Rescan notes")
        }
        .padding(8)
    }


    private func scan() async {
        loading = true
        defer { loading = false }
        let root = AppSettings.shared.notesFolder.path + "/"
        var result: [QItem] = []
        for f in NotesLibrary.meetingFiles(limit: AppSettings.shared.searchDepth) {
            guard let text = f.url.readText() else { continue }
            let qs = NotesLibrary.openQuestions(in: text)
            guard !qs.isEmpty else { continue }
            let title = FrontMatter.title(in: text) ?? f.displayName
            let rel = f.url.path.replacingOccurrences(of: root, with: "")
            let note = store.doc.notes.first { $0.filePath == rel }
            let orgIDs = Set(note.map { store.effectiveOrgIDs(of: $0) } ?? [])
            let projIDs = note.map { store.effectiveProjectIDs(of: $0) } ?? []
            let date = DateDisplay.posixDay.date(from: f.day)
            for q in qs {
                result.append(QItem(question: q.text, title: title, date: date, url: f.url,
                                    orgIDs: orgIDs, projIDs: projIDs, done: q.done, rawLine: q.rawLine))
            }
        }
        items = result
    }

    /// Tick a question answered (or back to open) — rewrites its checkbox in the
    /// source note, then updates the row in place (no full rescan).
    private func toggle(_ q: QItem) {
        guard let i = items.firstIndex(where: { $0.id == q.id }) else { return }
        let nowDone = !items[i].done
        NotesLibrary.setCheckbox(rawLine: items[i].rawLine, text: items[i].question,
                                 done: nowDone, inFile: items[i].url)
        items[i].done = nowDone
        items[i].rawLine = "- [\(nowDone ? "x" : " ")] \(items[i].question)"
    }
}

// MARK: POC Tracker (master list)

/// How a project's POC stands, derived from its criteria. Drives the tracker's
/// status filter, grouping, and per-row badge/tint.
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
private struct PhasePill: View {
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

private enum PocSort: String, CaseIterable, Identifiable {
    case priority = "At-risk first", deadline = "Deadline", name = "Name", progress = "Progress", recent = "Recent activity"
    var id: String { rawValue }
}
private enum PocGroup: String, CaseIterable, Identifiable {
    case phase = "Phase", health = "Health", account = "Account", project = "Project", date = "Date", none = "None"
    var id: String { rawValue }
}
/// The Status filter: the Open (planned/in-progress/on-hold) / Closed
/// (passed/failed) / All lifecycle scopes, plus a specific phase. Defaults to
/// Open in the tracker.
private enum PocStatusSel: Hashable, Identifiable {
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
private struct PocRow: Identifiable {
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
private struct PocProjectList: View {
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
private struct NewPocSheet: View {
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
private struct PocBulkAddSheet: View {
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
private struct PocCritNode: Identifiable {
    let criterion: PocCriterion
    let depth: Int
    var id: String { criterion.id }
}

private struct PocDetail: View {
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

private func splitList(_ s: String) -> [String] {
    s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
}
