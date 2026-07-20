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

enum CatalogSection: String, CaseIterable, Identifiable {
    // Declared in sidebar order so the enum and `sidebarGroups` can't drift:
    // Overview (where do I stand), then Records (everything captured), then
    // Track (the watch/resolve surfaces), then Explore (the graph lens).
    case dashboard     = "Dashboard"
    case reports       = "Reports"
    case notes         = "Notes"
    case recordings    = "Recordings"
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
        ("Records",  [.notes, .recordings, .organisations, .projects, .people, .tags]),
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
        case .recordings:    return "Recording"
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
        case .recordings:    return "waveform"
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
        case .recordings:    return .brown
        case .poc:           return .cyan
        case .radar:         return .red
        case .questions:     return .mint
        case .reports:       return .green
        }
    }
}

// MARK: Root

struct CatalogView: View {
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
        case .recordings:    return 0
        case .poc:           return store.allPocs.count
        case .radar:         return 0
        case .questions:     return 0
        case .reports:       return 0
        }
    }

    /// Sections that fill the content column and want no detail pane.
    private var wideCanvas: Bool { section == .dashboard || section == .questions || section == .reports || section == .recordings }
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
        } else if section == .recordings {
            RecordingsList(store: store)
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

func openNote(_ note: CatalogNote) {
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

struct NoteRow: View {
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
struct TimelineRow: View {
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
struct RelationshipTimeline: View {
    let notes: [CatalogNote]
    var body: some View {
        ForEach(notes.sortedByDateDescending) { TimelineRow(note: $0) }
    }
}

/// On-demand AI digest across an entity's recent notes — "where things stand".
/// Reads up to the 5 most recent notes and opens the summary in its own window.
struct RelationshipSummaryButton: View {
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

struct EmptyDetail: View {
    let section: CatalogSection
    var body: some View {
        ContentUnavailableView("No \(section.singular) selected",
                               systemImage: section.icon,
                               description: Text("Pick one from the list, or add a new \(section.singular.lowercased())."))
    }
}

// MARK: Content column

struct EntityList: View {
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
                case .dashboard, .map, .notes, .recordings, .poc, .radar, .questions, .reports: EmptyView()   // handled by CatalogView
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
        case .dashboard, .notes, .recordings, .poc, .radar, .questions, .reports:   break
        }
    }
}

// MARK: Detail column

struct EntityDetail: View {
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
struct EntityEditorView: View {
    @ObservedObject var store: CatalogStore
    let section: CatalogSection
    let id: String
    var onDelete: () -> Void

    var body: some View {
        switch section {
        case .dashboard, .map, .recordings, .poc, .radar, .questions, .reports: EmptyView()
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

struct RelationshipBadge: View {
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

struct StageBadge: View {
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

struct OrgEditor: View {
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

struct PersonEditor: View {
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
struct PersonTypePicker: View {
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
struct ManageTypesSheet: View {
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
struct BulkAddSheet: View {
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
struct BulkAssignSheet: View {
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

struct ProjectEditor: View {
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

struct TagEditor: View {
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

func splitList(_ s: String) -> [String] {
    s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
}
