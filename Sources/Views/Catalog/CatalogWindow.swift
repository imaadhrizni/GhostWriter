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

    /// Sidebar layout, grouped for scanning — five tight clusters (≤4 items each)
    /// so no single group sprawls:
    /// • **Overview** — the "where do I stand" surfaces (Dashboard, Reports).
    /// • **Records** — the raw captured artifacts (Notes, Recordings).
    /// • **Graph** — the CRM entities, in the deal-flow chain (org → project) kept
    ///   contiguous to match the Map tree, with People and Tags — the cross-cutting
    ///   per-note entities — last.
    /// • **Track** — the watch/resolve surfaces, led by the actionable inbox.
    /// • **Explore** — the graph lens over everything.
    static let sidebarGroups: [(title: String?, sections: [CatalogSection])] = [
        ("Overview", [.dashboard, .reports]),
        ("Records",  [.notes, .recordings]),
        ("Graph",    [.organisations, .projects, .people, .tags]),
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
    /// A note id awaiting reveal (select + scroll) in NotesList, set by the
    /// `.selectCatalogNote` handler and cleared by NotesList once handled.
    @State private var revealID: String?
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
        .onReceive(NotificationCenter.default.publisher(for: .selectCatalogNote)) { note in
            guard let id = note.object as? String, store.note(id: id) != nil else { return }
            // Switch to Notes and clear any active search/filters so the target
            // row is present in `filtered`, then hand the id to NotesList via
            // `revealID`. NotesList performs the actual select + expand + scroll
            // on appear/change, which is race-free regardless of whether the list
            // was already mounted when the reveal arrived.
            resetNotes()
            section = .notes
            revealID = id
        }
        .onReceive(NotificationCenter.default.publisher(for: .showCatalogNotes)) { _ in
            resetNotes()
            section = .notes
        }
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
            DashboardView(store: store) { section = $0 }
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
                        NotesList(store: store, selID: $selID, reveal: $revealID,
                                  query: query, scope: scope,
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
                let total = store.doc.notes.count
                let missing = store.missingNotes.count
                let totalLabel = "\(total) note\(total == 1 ? "" : "s")"
                if n > 0 {
                    status = "Imported \(n) · \(totalLabel) total"
                } else {
                    status = "Up to date — \(totalLabel)" + (missing > 0 ? " · \(missing) missing" : "")
                }
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
