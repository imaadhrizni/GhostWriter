import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Catalog Window
//
// A three-column browser over the catalog: sections → items → editor.
// Organisations form an unlimited hierarchy and their *relationship* is a
// property of the root (descendants inherit it). Projects belong to orgs;
// opportunities belong to projects. Notes link directly only to organisations,
// projects and tags — their people and opportunities are inherited through the
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
    // the two ways to browse first, then records in containment order.
    case dashboard     = "Dashboard"
    case notes         = "Notes"
    case map           = "Map"
    case organisations = "Organisations"
    case projects      = "Projects"
    case opportunities = "Opportunities"
    case people        = "People"
    case tags          = "Tags"
    case poc           = "POC Tracker"
    case radar         = "Keyword Radar"
    var id: String { rawValue }

    /// Sidebar layout: the two ways to look at the catalog on top (Notes is the
    /// primary document list; Map is the graph explorer), then the records with
    /// the deal-flow chain kept contiguous (org → project → opportunity) to
    /// match the Map tree, with People — a cross-cutting per-note entity like
    /// Tags — sitting last.
    static let sidebarGroups: [(title: String?, sections: [CatalogSection])] = [
        ("Overview", [.dashboard]),
        ("Browse",   [.notes, .map]),
        ("Records",  [.organisations, .projects, .opportunities, .people]),
        ("Labels",   [.tags]),
        ("Tools",    [.poc, .radar]),
    ]

    var singular: String {
        switch self {
        case .dashboard:     return "Dashboard"
        case .map:           return "Item"
        case .organisations: return "Organisation"
        case .people:        return "Person"
        case .projects:      return "Project"
        case .opportunities: return "Opportunity"
        case .tags:          return "Tag"
        case .notes:         return "Note"
        case .poc:           return "POC"
        case .radar:         return "Term"
        }
    }
    var icon: String {
        switch self {
        case .dashboard:     return "square.grid.2x2.fill"
        case .map:           return "point.3.filled.connected.trianglepath.dotted"
        case .organisations: return "building.2"
        case .people:        return "person.2"
        case .projects:      return "folder"
        case .opportunities: return "chart.line.uptrend.xyaxis"
        case .tags:          return "tag"
        case .notes:         return "doc.text"
        case .poc:           return "flask"
        case .radar:         return "dot.radiowaves.left.and.right"
        }
    }
    var tint: Color {
        switch self {
        case .dashboard:     return .accentColor
        case .map:           return .purple
        case .organisations: return .blue
        case .people:        return .teal
        case .projects:      return .orange
        case .opportunities: return .green
        case .tags:          return .pink
        case .notes:         return .indigo
        case .poc:           return .cyan
        case .radar:         return .pink
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
    @State private var fOrg = ""
    @State private var fProject = ""
    @State private var fOpp = ""
    @State private var fTag = ""
    @State private var fPerson = ""
    @State private var fUnassigned = false
    @State private var fMissing = false
    @State private var scope: NoteSearchScope = .text
    @State private var askNonce = 0
    private var anyFilter: Bool { !(fOrg.isEmpty && fProject.isEmpty && fOpp.isEmpty && fTag.isEmpty && fPerson.isEmpty) || fUnassigned || fMissing }
    private var canAsk: Bool { !AppSettings.shared.localOnlyMode && KeychainService.groqAPIKey() != nil }

    /// Notes matching the active facet filters (ignoring the query — in Ask mode
    /// the query is the question). These scope what Ask retrieves from.
    private var askFiles: [NotesLibrary.MeetingFile] {
        store.doc.notes.filter { n in
            (fOrg.isEmpty || store.effectiveOrgIDs(of: n).contains(fOrg))
            && (fProject.isEmpty || store.effectiveProjectIDs(of: n).contains(fProject))
            && (fOpp.isEmpty || n.opportunityIDs.contains(fOpp))
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
        if let o = store.opportunity(fOpp) { parts.append(o.name) }
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
        case .opportunities: return store.doc.opportunities.count
        case .tags:          return store.doc.tags.count
        case .notes:         return store.doc.notes.count
        case .poc:           return store.doc.opportunities.filter { !$0.pocCriteria.isEmpty }.count
        case .radar:         return 0
        }
    }

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
                // The Dashboard is a wide canvas (cards fill this column); every
                // other section is a normal master list, so cap it narrower.
                .navigationSplitViewColumnWidth(
                    min: section == .dashboard ? 460 : 240,
                    ideal: section == .dashboard ? 640 : 285,
                    max: section == .dashboard ? 5000 : 400)
                .navigationTitle(section.rawValue)
        } detail: {
            if section == .dashboard {
                // The dashboard is self-contained (KPIs + cards all live in the
                // content column), so collapse the detail column away — no blank
                // pane on the right.
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
                PocDetail(store: store, oppID: selID)
                    .frame(minWidth: 360)
            } else if section == .radar {
                RadarTermDetail(model: radarModel, term: selID)
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
            Text("Deletes every organisation, person, project, opportunity, tag and note link. Your Markdown note files are not touched. This cannot be undone.")
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
            RadarTermList(model: radarModel, selID: $selID)
        } else if section == .map {
            MapTree(store: store) { sec, id in mapSection = sec; mapID = id }
        } else if section == .poc {
            PocOpportunityList(store: store, selID: $selID)
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
                                  fOrg: fOrg, fProject: fProject, fOpp: fOpp, fTag: fTag, fPerson: fPerson,
                                  unassignedOnly: fUnassigned, missingOnly: fMissing)
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

                filterMenu
                    .menuStyle(.borderlessButton)
                    .fixedSize()
            }

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
        [fOrg, fProject, fOpp, fPerson, fTag].filter { !$0.isEmpty }.count
            + (fUnassigned ? 1 : 0) + (fMissing ? 1 : 0)
    }

    private func clearFilters() {
        fOrg = ""; fProject = ""; fOpp = ""; fTag = ""; fPerson = ""
        fUnassigned = false; fMissing = false
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
            facetSubmenu("Org", "building.2", $fOrg, store.orgsSorted.map { ($0.id, store.orgPath(of: $0.id)) })
            facetSubmenu("Project", "folder", $fProject, store.doc.projects.sortedByName.map { ($0.id, $0.name) })
            facetSubmenu("Opportunity", "chart.line.uptrend.xyaxis", $fOpp, store.doc.opportunities.sortedByName.map { ($0.id, $0.name) })
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
                    if let o = store.org(fOrg)         { filterChip(o.name, .blue)      { fOrg = "" } }
                    if let p = store.project(fProject) { filterChip(p.name, .teal)      { fProject = "" } }
                    if let o = store.opportunity(fOpp) { filterChip(o.name, .green)     { fOpp = "" } }
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
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.16)))
            .foregroundStyle(color)
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
            .help("Create an organisation → project → opportunity → people → tags in one go")
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
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Catalog.json"
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
            status = "Exported catalog"
        } catch {
            status = "Export failed: \(error.localizedDescription)"
        }
    }

    /// Pick a `.json` file, validate it, then offer merge/replace.
    private func importCatalog() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
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
    /// When set, called on finish with the resolved opportunity id (or nil) —
    /// used by the Start Meeting flow. Otherwise the sheet just dismisses.
    var onComplete: ((String?) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    private static let new = "__new__"   // "＋ New …" sentinel

    // Org: an existing id or "__new__" (+ fields for the new case).
    @State private var orgSel = QuickAddSheet.new
    @State private var orgName = ""
    @State private var parentID = ""
    @State private var relationship: OrgRelationship = .customer
    // Project / Opportunity: "" (none), an existing id, or "__new__".
    @State private var projSel = ""
    @State private var projName = ""
    @State private var oppSel = ""
    @State private var oppName = ""
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
        return store.projects(forOrg: id).sortedByName
    }
    private var oppsForProject: [CatalogOpportunity] {
        guard projSel != Self.new, !projSel.isEmpty else { return [] }
        return store.opportunities(forProject: projSel).sortedByName
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
                        ForEach(projectsForOrg) { Text($0.name).tag($0.id) }
                        Divider()
                        Text("＋ New project").tag(Self.new)
                    }
                    if projSel == Self.new { TextField("New name", text: $projName) }
                }
                Section("Opportunity") {
                    Picker("Opportunity", selection: $oppSel) {
                        Text("None").tag("")
                        ForEach(oppsForProject) { Text($0.name).tag($0.id) }
                        Divider()
                        Text("＋ New opportunity").tag(Self.new)
                    }
                    if oppSel == Self.new { TextField("New name", text: $oppName) }
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
            .onChange(of: orgSel) { _, _ in projSel = ""; oppSel = "" }
            .onChange(of: projSel) { _, _ in oppSel = "" }
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

        // Opportunity — existing, new (under the project), or none.
        var resolvedOppID: String?
        if oppSel == Self.new {
            let name = oppName.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { resolvedOppID = store.addOpportunity(name: name, projectID: projectID).id }
        } else if !oppSel.isEmpty {
            resolvedOppID = oppSel
        }

        // People are org-independent — existing selections already exist; just
        // create any new names so they're available to pick on notes.
        for name in splitList(newPeople) { _ = store.addPerson(name: name) }

        // Tags — existing selections already exist; just create the new ones.
        for name in splitList(newTags) { _ = store.addTag(name: name) }

        finish(resolvedOppID)
    }

    private func finish(_ oppID: String?) {
        if let onComplete { onComplete(oppID) } else { dismiss() }
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
            guard let text = try? String(contentsOf: e.url, encoding: .utf8), !text.isEmpty else { continue }
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
                case .dashboard, .map, .notes, .poc, .radar: EmptyView()   // handled by CatalogView
                case .organisations: orgList
                case .people:        peopleList
                case .projects:      projectList
                case .opportunities: oppList
                case .tags:          tagList
                }
            }
        }
        .toolbar {
            if section != .notes {
                ToolbarItem {
                    Button { add() } label: { Label("Add", systemImage: "plus") }
                        .help("Add \(section.singular)")
                }
            }
        }
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

    private var peopleList: some View {
        List(store.doc.people.sortedByName.filter { matches($0.name) }, selection: $selID) {
            Text($0.name).tag($0.id)
        }
    }

    /// Projects grouped by their organisation, then by project name.
    private var sortedProjects: [CatalogProject] {
        store.doc.projects.sorted { a, b in
            let oa = store.org(a.orgID).map { store.orgPath(of: $0.id) } ?? "~"
            let ob = store.org(b.orgID).map { store.orgPath(of: $0.id) } ?? "~"
            if oa.caseInsensitiveCompare(ob) != .orderedSame {
                return oa.localizedCaseInsensitiveCompare(ob) == .orderedAscending
            }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    private var projectList: some View {
        List(sortedProjects.filter { matches($0.name) }, selection: $selID) { p in
            VStack(alignment: .leading, spacing: 2) {
                Text(p.name).lineLimit(1)
                Text(store.org(p.orgID).map { store.orgPath(of: $0.id) } ?? "No organisation")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.vertical, 3)
            .tag(p.id)
        }
    }

    private var oppList: some View {
        List(store.doc.opportunities.sortedByName.filter { matches($0.name) }, selection: $selID) { o in
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(o.name).lineLimit(1)
                    Text(store.project(o.projectID)?.name ?? "Unassigned")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                StageBadge(o.stage)
            }
            .padding(.vertical, 3)
            .tag(o.id)
        }
    }

    private var tagList: some View {
        List(store.tagsSorted.filter { matches($0.name) }, selection: $selID) { t in
            HStack {
                Text(t.name)
                Spacer()
                Text("\(store.notes(forTag: t.id).count)").font(.caption).foregroundStyle(.secondary)
            }.tag(t.id)
        }
    }

    private func add() {
        switch section {
        case .map:           break
        case .organisations: selID = store.addOrg(name: "New Organisation").id
        case .people:        selID = store.addPerson(name: "New Person").id
        case .projects:      selID = store.addProject(name: "New Project").id
        case .opportunities: selID = store.addOpportunity(name: "New Opportunity").id
        case .tags:
            // addTag folds by name, so pick a name that doesn't already exist —
            // otherwise "+" would just re-select the existing "New Tag".
            let existing = Set(store.doc.tags.map { $0.name.lowercased() })
            var name = "New Tag", n = 2
            while existing.contains(name.lowercased()) { name = "New Tag \(n)"; n += 1 }
            selID = store.addTag(name: name).id
        case .dashboard, .notes, .poc, .radar:   break
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
        case .dashboard, .map, .poc, .radar: EmptyView()
        case .organisations:
            if let o = store.org(id) { OrgEditor(store: store, org: o, onDelete: onDelete) } else { missing }
        case .people:
            if let p = store.person(id) { PersonEditor(store: store, person: p, onDelete: onDelete) } else { missing }
        case .projects:
            if let p = store.project(id) { ProjectEditor(store: store, project: p, onDelete: onDelete) } else { missing }
        case .opportunities:
            if let o = store.opportunity(id) { OpportunityEditor(store: store, opp: o, onDelete: onDelete) } else { missing }
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
    var body: some View {
        Text(text)
            .font(.caption2).fontWeight(.medium)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.16)))
            .foregroundStyle(color)
    }
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
                Picker("Parent", selection: Binding(
                    get: { draft.parentID ?? "" },
                    set: { draft.parentID = $0.isEmpty ? nil : $0; commit() })) {
                    Text("None (top level)").tag("")
                    ForEach(store.parentChoices(for: draft.id)) { Text(store.orgPath(of: $0.id)).tag($0.id) }
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

    /// Person "Type" — where they sit relative to you.
    private static let types: [(String, String)] = [
        ("", "Unknown"), ("internal", "Internal"), ("external", "External"),
        ("customer", "Customer"), ("prospect", "Prospect"), ("partner", "Partner"),
    ]

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $draft.name).onSubmit(commit)
                Picker("Type", selection: Binding(
                    get: { draft.channel ?? "" },
                    set: { draft.channel = $0.isEmpty ? nil : $0; commit() })) {
                    ForEach(Self.types, id: \.0) { Text($0.1).tag($0.0) }
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

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $draft.name).onSubmit(commit)
                Picker("Organisation", selection: Binding(
                    get: { draft.orgID ?? "" },
                    set: { draft.orgID = $0.isEmpty ? nil : $0; commit() })) {
                    Text("None").tag("")
                    ForEach(store.orgsSorted) { Text(store.orgPath(of: $0.id)).tag($0.id) }
                }
                Toggle("Archived", isOn: Binding(get: { draft.archived }, set: { draft.archived = $0; commit() }))
            }
            let opps = store.opportunities(forProject: draft.id)
            if !opps.isEmpty {
                Section("Opportunities") { ForEach(opps) { o in HStack { Text(o.name); Spacer(); StageBadge(o.stage) } } }
            }
            Section { Button("Delete Project", role: .destructive) { store.deleteProject(draft.id); onDelete() } }
        }
        .formStyle(.grouped)
        .navigationTitle(draft.name.isEmpty ? "Project" : draft.name)
        .onDisappear(perform: commit)
    }
}

// MARK: Opportunity editor (project-only; org derived)

private struct OpportunityEditor: View {
    @ObservedObject var store: CatalogStore
    @State private var draft: CatalogOpportunity
    var onDelete: () -> Void

    init(store: CatalogStore, opp: CatalogOpportunity, onDelete: @escaping () -> Void) {
        self.store = store; _draft = State(initialValue: opp); self.onDelete = onDelete
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
                Picker("Project", selection: Binding(
                    get: { draft.projectID ?? "" },
                    set: { draft.projectID = $0.isEmpty ? nil : $0; commit() })) {
                    Text("Unassigned").tag("")
                    ForEach(store.doc.projects.sortedByName) { Text($0.name).tag($0.id) }
                }
                LabeledContent("Organisation", value: store.org(forOpportunity: draft).map { store.orgPath(of: $0.id) } ?? "—")
                Picker("Stage", selection: Binding(get: { draft.stage }, set: { draft.stage = $0; commit() })) {
                    ForEach(OppStage.allCases) { Text($0.label).tag($0) }
                }
                TextField("Value (\(draft.currency))", text: dollars).onSubmit(commit)
            }
            let notes = store.notes(forOpportunity: draft)
            if !notes.isEmpty {
                Section("Relationship") { RelationshipSummaryButton(store: store, entityName: draft.name, notes: notes) }
                Section("Timeline") { RelationshipTimeline(notes: notes) }
            }
            Section { Button("Delete Opportunity", role: .destructive) { store.deleteOpportunity(draft.id); onDelete() } }
        }
        .formStyle(.grouped)
        .navigationTitle(draft.name.isEmpty ? "Opportunity" : draft.name)
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
    let fOrg: String, fProject: String, fOpp: String, fTag: String, fPerson: String
    var unassignedOnly: Bool = false
    var missingOnly: Bool = false
    @State private var semanticOrder: [String] = []
    @State private var hovered: String?

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }

    private func facetFiltered(_ notes: [CatalogNote]) -> [CatalogNote] {
        var ns = notes
        if !fOrg.isEmpty { ns = ns.filter { store.effectiveOrgIDs(of: $0).contains(fOrg) } }
        if !fProject.isEmpty { ns = ns.filter { store.effectiveProjectIDs(of: $0).contains(fProject) } }
        if !fOpp.isEmpty { ns = ns.filter { $0.opportunityIDs.contains(fOpp) } }
        if !fTag.isEmpty { ns = ns.filter { $0.tagIDs.contains(fTag) } }
        if !fPerson.isEmpty { ns = ns.filter { $0.personIDs.contains(fPerson) } }
        if unassignedOnly { ns = ns.filter(store.isUnassigned) }
        if missingOnly { ns = ns.filter { !store.fileExists($0) } }
        return ns
    }

    private var filtered: [CatalogNote] {
        if scope == .meaning && !trimmedQuery.isEmpty {
            let rank = Dictionary(uniqueKeysWithValues: semanticOrder.enumerated().map { ($0.element, $0.offset) })
            let base = store.doc.notes.filter { rank[$0.id] != nil }
                .sorted { (rank[$0.id] ?? 0) < (rank[$1.id] ?? 0) }
            return facetFiltered(base)
        }
        var ns = store.doc.notes
        if !trimmedQuery.isEmpty { ns = ns.filter { store.noteMatches($0, query: trimmedQuery) } }
        return facetFiltered(ns).sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
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
                List(filtered, selection: $selID) { n in
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
                        // Row actions — always shown for missing rows (they need
                        // triage), otherwise revealed on hover to keep it clean.
                        if hovered == n.id || missing {
                            if !missing {
                                Button {
                                    NSWorkspace.shared.activateFileViewerSelecting([store.url(of: n)])
                                } label: { Image(systemName: "folder") }
                                .buttonStyle(.borderless).foregroundStyle(.secondary)
                                .help("Reveal in Finder")
                            }
                            Button {
                                if selID == n.id { selID = nil }
                                store.deleteNote(n.id)
                            } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).foregroundStyle(missing ? .red : .secondary)
                            .help(missing ? "Remove this missing entry from the catalog"
                                          : "Remove from catalog (note file is kept)")
                        }
                    }
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                    .onHover { hovered = $0 ? n.id : (hovered == n.id ? nil : hovered) }
                    .tag(n.id)
                }
                .overlay { if filtered.isEmpty { ContentUnavailableView.search } }
            }
        }
        .task(id: "\(scope)|\(trimmedQuery)") { await runSemantic() }
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
            guard let body = try? String(contentsOf: f.url, encoding: .utf8) else { continue }
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

    var body: some View {
        Form {
            Section {
                Button { openNote(note) } label: { Label("Open note", systemImage: "arrow.up.forward.app") }
                if let d = note.date { LabeledContent("Date") { Text(d.formatted(date: .abbreviated, time: .shortened)) } }
            }

            // Single "Filed under": the note's opportunity OR org, as removable
            // chips. One Assign… control handles both (mutually exclusive).
            Section("Filed under") {
                let opps = store.doc.opportunities.filter { current.opportunityIDs.contains($0.id) }
                let orgsDirect = store.orgsSorted.filter { current.orgIDs.contains($0.id) }
                if opps.isEmpty && orgsDirect.isEmpty {
                    Text("Unassigned").font(.caption).foregroundStyle(.secondary)
                } else {
                    FlowChips {
                        ForEach(opps) { o in
                            Chip(text: o.name, color: .green) { store.setOpportunity(o.id, on: note.id, false) }
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
                // Inherited context (read-only).
                let viaOpp = store.effectiveOrgIDs(of: current).subtracting(current.orgIDs)
                if !viaOpp.isEmpty {
                    Text("Org via opportunity: " + store.orgsSorted.filter { viaOpp.contains($0.id) }
                        .map { store.orgPath(of: $0.id) }.joined(separator: ", "))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                let projIDs = store.effectiveProjectIDs(of: current)
                if !projIDs.isEmpty {
                    Text("Projects: " + store.doc.projects.filter { projIDs.contains($0.id) }
                        .map { $0.name }.joined(separator: ", "))
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
                    Text("Words pulled from the note — tap one to add it as a tag, person, opportunity, organisation, or project.")
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
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.16)))
        .foregroundStyle(color)
    }
}

/// Simple wrapping layout for chips.
private struct FlowChips<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { FlowLayout(spacing: 6) { content } }
}

/// A "+ add…" button that opens a searchable picker of existing options, with a
/// "Create …" row when the query matches nothing.
private struct AddChipButton: View {
    let title: String
    let placeholder: String
    let options: [(id: String, name: String)]
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
                VStack(spacing: 6) {
                    EntitySearchBar(text: $query, placeholder: placeholder)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(matches, id: \.id) { opt in
                                Button { onPick(opt.id); query = ""; show = false } label: {
                                    HStack { Text(opt.name); Spacer(); Image(systemName: "plus") }
                                        .contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                            if !q.isEmpty && !exact {
                                Button { onCreate(q); query = ""; show = false } label: {
                                    Label("Create “\(q)”", systemImage: "plus.circle.fill")
                                }.buttonStyle(.plain).foregroundStyle(.tint)
                            }
                            if matches.isEmpty && q.isEmpty {
                                Text("Nothing to add").font(.caption).foregroundStyle(.secondary)
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

/// The Assign… picker: choose an opportunity OR an organisation (mutually
/// exclusive). Assigning clears the other side via the store helpers.
private struct AssignPopover: View {
    @ObservedObject var store: CatalogStore
    let noteID: String
    @Binding var show: Bool
    @State private var mode = 0   // 0 = opportunity, 1 = organisation
    @State private var query = ""

    var body: some View {
        VStack(spacing: 8) {
            Picker("", selection: $mode) {
                Text("Opportunity").tag(0)
                Text("Organisation").tag(1)
            }
            .pickerStyle(.segmented).labelsHidden()
            EntitySearchBar(text: $query, placeholder: mode == 0 ? "Search opportunities" : "Search organisations")
            let q = query.trimmingCharacters(in: .whitespaces)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if mode == 0 {
                        let opps = store.doc.opportunities.sortedByName
                            .filter { q.isEmpty || $0.name.localizedCaseInsensitiveContains(q) }
                        if opps.isEmpty { Text("No opportunities").font(.caption).foregroundStyle(.secondary) }
                        ForEach(opps) { o in
                            Button { store.setOpportunity(o.id, on: noteID, true); show = false } label: {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(o.name)
                                    if let path = oppPath(o) { Text(path).font(.caption2).foregroundStyle(.secondary) }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    } else {
                        let orgs = store.orgsSorted
                            .filter { q.isEmpty || store.orgPath(of: $0.id).localizedCaseInsensitiveContains(q) }
                        if orgs.isEmpty { Text("No organisations").font(.caption).foregroundStyle(.secondary) }
                        ForEach(orgs) { o in
                            Button { store.setOrg(o.id, on: noteID, true); show = false } label: {
                                Text(store.orgPath(of: o.id))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 4)
            }
            .frame(maxHeight: 240)
        }
        .padding(10).frame(width: 280)
    }

    private func oppPath(_ o: CatalogOpportunity) -> String? {
        guard let p = store.project(o.projectID) else { return nil }
        var parts: [String] = []
        if let org = store.org(p.orgID) { parts.append(store.orgPath(of: org.id)) }
        parts.append(p.name)
        return parts.joined(separator: " › ")
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
/// the note's hierarchy (people attach to the note's orgs; opps to its project).
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
            Button(action: addOpportunity) { Label("Opportunity", systemImage: "chart.line.uptrend.xyaxis") }
            Divider()
            // Created only — assign them yourself:
            Button { _ = store.addOrg(name: token); onDone() }
                label: { Label("Organisation (create only)", systemImage: "building.2") }
            Button { _ = store.addProject(name: token); onDone() }
                label: { Label("Project (create only)", systemImage: "folder") }
        } label: {
            if asChip {
                HStack(spacing: 4) {
                    Text(token).font(.caption).lineLimit(1)
                    Image(systemName: "plus").font(.system(size: 8, weight: .bold))
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(Color.secondary.opacity(0.15)))
                .foregroundStyle(.secondary)
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
    private func addOpportunity() {
        let projectID = note?.projectIDs.first
        let o = store.addOpportunity(name: token, projectID: projectID)
        store.setOpportunity(o.id, on: noteID, true)                        // assign to the note
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

private struct MapTree: View {
    @ObservedObject var store: CatalogStore
    let onPick: MapPick
    @State private var search = ""
    @StateObject private var exp = MapExpansion()

    private var q: String { search.trimmingCharacters(in: .whitespaces).lowercased() }

    /// Every container node's id — used to expand the whole tree at once.
    private var allNodeIDs: Set<String> {
        Set(store.doc.orgs.map(\.id))
            .union(store.doc.projects.map(\.id))
            .union(store.doc.opportunities.map(\.id))
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
    private var rootOrgs: [CatalogOrg] { store.rootOrgs.filter(matches) }
    private var orphanProjects: [CatalogProject] {
        store.doc.projects.sortedByName
            .filter { $0.orgID == nil || store.org($0.orgID) == nil }
            .filter { q.isEmpty || $0.name.lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
                TextField("Filter organisations", text: $search).textFieldStyle(.plain)
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.tertiary)
                }
                Divider().frame(height: 14)
                Button { exp.open = allNodeIDs } label: { Image(systemName: "chevron.down.square") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Expand all")
                    .disabled(exp.open.count == allNodeIDs.count)
                Button { exp.open = [] } label: { Image(systemName: "chevron.right.square") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Collapse all")
                    .disabled(exp.open.isEmpty)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            Divider()
            List {
                if store.doc.orgs.isEmpty && store.doc.projects.isEmpty {
                    Text("Nothing to map yet — add organisations, or import notes.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(rootOrgs) { OrgMapNode(store: store, org: $0, exp: exp, onPick: onPick) }
                if !orphanProjects.isEmpty {
                    Section("No organisation") {
                        ForEach(orphanProjects) { ProjectMapNode(store: store, project: $0, exp: exp, onPick: onPick) }
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
    let onPick: MapPick
    var body: some View {
        DisclosureGroup(isExpanded: exp.binding(org.id)) {
            ForEach(store.childOrgs(of: org.id)) { OrgMapNode(store: store, org: $0, exp: exp, onPick: onPick) }
            ForEach(store.projects(forOrg: org.id)) { ProjectMapNode(store: store, project: $0, exp: exp, onPick: onPick) }
            // Internal notes attached directly to this org (no opportunity).
            ForEach(store.notes(directlyOnOrg: org.id).sortedByDateDescending) { NoteMapNode(store: store, note: $0, exp: exp, onPick: onPick) }
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
    let onPick: MapPick
    var body: some View {
        DisclosureGroup(isExpanded: exp.binding(project.id)) {
            let opps = store.opportunities(forProject: project.id)
            if opps.isEmpty { Text("No opportunities").font(.caption2).foregroundStyle(.secondary) }
            ForEach(opps) { OppMapNode(store: store, opp: $0, exp: exp, onPick: onPick) }
        } label: {
            MapRow(icon: "folder", tint: .orange, title: project.name) { onPick(.projects, project.id) }
        }
    }
}

private struct OppMapNode: View {
    @ObservedObject var store: CatalogStore
    let opp: CatalogOpportunity
    @ObservedObject var exp: MapExpansion
    let onPick: MapPick
    var body: some View {
        DisclosureGroup(isExpanded: exp.binding(opp.id)) {
            let notes = store.notes(forOpportunity: opp).sortedByDateDescending
            if notes.isEmpty { Text("No notes").font(.caption2).foregroundStyle(.secondary) }
            ForEach(notes) { NoteMapNode(store: store, note: $0, exp: exp, onPick: onPick) }
        } label: {
            MapRow(icon: "chart.line.uptrend.xyaxis", tint: .green, title: opp.name,
                   trailing: AnyView(StageBadge(opp.stage))) { onPick(.opportunities, opp.id) }
        }
    }
}

/// A note in the map, expandable to its own people and tags. Falls back to a
/// plain row when it has neither, so leaf notes don't show an empty twisty.
private struct NoteMapNode: View {
    @ObservedObject var store: CatalogStore
    let note: CatalogNote
    @ObservedObject var exp: MapExpansion
    let onPick: MapPick

    var body: some View {
        let people = store.people(of: note)
        let tags = store.tags(of: note)
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

// MARK: - POC Tracker (Catalog section)
//
// POC success criteria hang off a Catalog opportunity (`pocCriteria`), so the
// tracker lives here rather than in a standalone window: pick an opportunity in
// the middle column, edit its criteria in the detail pane. The detail pane can
// also seed criteria from the opportunity's linked meetings (the "bridge").

/// Middle column: opportunities, each showing POC progress at a glance.
private struct PocOpportunityList: View {
    @ObservedObject var store: CatalogStore
    @Binding var selID: String?

    private func label(_ o: CatalogOpportunity) -> String {
        if let pid = o.projectID, let proj = store.project(pid) {
            if let oid = proj.orgID, let org = store.org(oid) { return org.name }
            return proj.name
        }
        return "—"
    }

    var body: some View {
        Group {
            if store.doc.opportunities.isEmpty {
                ContentUnavailableView("No opportunities", systemImage: "chart.line.uptrend.xyaxis",
                    description: Text("Add an opportunity under Records, then track its POC here."))
            } else {
                List(store.doc.opportunities.sortedByName, selection: $selID) { o in
                    let total = o.pocCriteria.count
                    let passed = o.pocCriteria.filter { $0.status == .pass }.count
                    HStack(spacing: 10) {
                        Image(systemName: "flask")
                            .foregroundStyle(.white).frame(width: 20, height: 20)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Color.cyan))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(o.name)
                            Text(label(o)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if total > 0 {
                            Text("\(passed)/\(total)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(passed == total ? .green : .secondary)
                        }
                    }
                    .tag(o.id)
                }
            }
        }
    }
}

/// Detail pane: the selected opportunity's POC criteria — add, cycle status,
/// remove, and seed from linked meetings.
private struct PocDetail: View {
    @ObservedObject var store: CatalogStore
    let oppID: String?
    @State private var newCriterion = ""
    @State private var suggesting = false
    @State private var status = ""

    private var opp: CatalogOpportunity? { oppID.flatMap { store.opportunity($0) } }

    /// The bridge can run only when cloud AI is available and the opportunity
    /// has at least one linked meeting to read.
    private var canSuggest: Bool {
        guard let opp else { return false }
        return !AppSettings.shared.localOnlyMode && !store.notes(forOpportunity: opp).isEmpty
    }

    var body: some View {
        if let opp {
            VStack(alignment: .leading, spacing: 14) {
                header(opp)
                if opp.pocCriteria.isEmpty {
                    ContentUnavailableView("No success criteria yet", systemImage: "checklist",
                        description: Text("Add the measurable outcomes this POC must prove — or seed them from the opportunity's meetings."))
                        .frame(maxHeight: .infinity)
                } else {
                    criteriaList(opp)
                }
                addBar(opp)
            }
            .padding(18)
            .animation(.default, value: status)
        } else {
            ContentUnavailableView("Select an opportunity", systemImage: "flask",
                description: Text("Pick an opportunity to track its proof-of-concept criteria."))
        }
    }

    @ViewBuilder private func header(_ opp: CatalogOpportunity) -> some View {
        let total = opp.pocCriteria.count
        let passed = opp.pocCriteria.filter { $0.status == .pass }.count
        let failed = opp.pocCriteria.filter { $0.status == .fail }.count
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "flask").foregroundStyle(.cyan)
                Text(opp.name).font(.title3.weight(.semibold))
                Spacer()
                Button {
                    suggestFromMeetings(opp)
                } label: {
                    if suggesting { ProgressView().controlSize(.small) }
                    else { Label("Suggest from meetings", systemImage: "sparkles") }
                }
                .disabled(!canSuggest || suggesting)
                .help(canSuggest
                      ? "Read this opportunity's linked meetings and add the success criteria they mention"
                      : "Needs cloud AI (not Local-only) and at least one meeting linked to this opportunity")
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

    private func criteriaList(_ opp: CatalogOpportunity) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(opp.pocCriteria) { c in
                    HStack(alignment: .top, spacing: 10) {
                        Button { store.setPocStatus(c.status.next, criterionID: c.id, oppID: opp.id) } label: {
                            Image(systemName: statusIcon(c.status)).foregroundStyle(statusColor(c.status))
                                .font(.system(size: 16))
                        }
                        .buttonStyle(.plain).help("Click to cycle: Pending → Passed → Failed")
                        Text(c.text)
                            .strikethrough(c.status == .pass, color: .secondary)
                            .foregroundStyle(c.status == .fail ? Color.red : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(c.status.label).font(.caption).foregroundStyle(statusColor(c.status))
                        Button { store.removePocCriterion(c.id, from: opp.id) } label: {
                            Image(systemName: "xmark.circle").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain).help("Remove criterion")
                    }
                    .padding(.vertical, 8)
                    Divider()
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func addBar(_ opp: CatalogOpportunity) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                // Multi-line so you can paste a whole list at once — one
                // criterion per line (commas also split). ⌥⏎ for a newline;
                // ⏎ commits.
                TextField("Add a success criterion… (one per line to add several)",
                          text: $newCriterion, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .onSubmit { commitAdd(opp) }
                Button("Add") { commitAdd(opp) }
                    .disabled(newCriterion.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if splitCriteria(newCriterion).count > 1 {
                Text("Adds \(splitCriteria(newCriterion).count) criteria")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Split the add field into individual criteria — one per line, and commas
    /// split too — so a pasted list becomes many criteria at once.
    private func splitCriteria(_ s: String) -> [String] {
        s.split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func commitAdd(_ opp: CatalogOpportunity) {
        let items = splitCriteria(newCriterion)
        guard !items.isEmpty else { return }
        let added = store.addPocCriteriaTexts(items, to: opp.id)
        newCriterion = ""
        if items.count > 1 {
            status = added == 0 ? "All already tracked."
                                : "Added \(added) criteri\(added == 1 ? "on" : "a")."
        } else {
            status = ""
        }
    }

    /// Bridge: read the opportunity's linked meeting notes, extract POC success
    /// criteria, and add the new ones (deduped). Non-destructive — everything
    /// added is editable/removable like a hand-typed criterion.
    private func suggestFromMeetings(_ opp: CatalogOpportunity) {
        let notes = store.notes(forOpportunity: opp)
        let transcripts = notes.compactMap { try? String(contentsOf: store.url(of: $0), encoding: .utf8) }
        guard !transcripts.isEmpty else { status = "No readable meetings linked to this opportunity."; return }
        // Cap the combined text so a busy opportunity doesn't blow the context.
        let combined = String(transcripts.joined(separator: "\n\n---\n\n").prefix(40_000))
        let oppID = opp.id
        suggesting = true
        status = "Reading \(transcripts.count) meeting\(transcripts.count == 1 ? "" : "s")…"
        Task { @MainActor in
            defer { suggesting = false }
            do {
                let criteria = try await TextPolisher().extractPocCriteria(transcript: combined)
                guard !criteria.isEmpty else { status = "No success criteria found in the linked meetings."; return }
                let added = store.addPocCriteriaTexts(criteria, to: oppID)
                status = added == 0
                    ? "Found \(criteria.count) — all already tracked."
                    : "Added \(added) criteri\(added == 1 ? "on" : "a") from \(transcripts.count) meeting\(transcripts.count == 1 ? "" : "s")."
            } catch {
                status = "Suggest failed: \(error.localizedDescription)"
            }
        }
    }

    private func statusIcon(_ s: PocStatus) -> String {
        switch s { case .pending: return "circle"; case .pass: return "checkmark.circle.fill"; case .fail: return "xmark.circle.fill" }
    }
    private func statusColor(_ s: PocStatus) -> Color {
        switch s { case .pending: return .secondary; case .pass: return .green; case .fail: return .red }
    }
}

// MARK: Small helpers

private func splitList(_ s: String) -> [String] {
    s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
}
