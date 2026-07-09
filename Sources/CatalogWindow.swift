import SwiftUI
import AppKit

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
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 580),
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

    func showAndActivate() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: Sections

private enum CatalogSection: String, CaseIterable, Identifiable {
    case map           = "Map"
    case organisations = "Organisations"
    case people        = "People"
    case projects      = "Projects"
    case opportunities = "Opportunities"
    case tags          = "Tags"
    case notes         = "Notes"
    var id: String { rawValue }
    var singular: String {
        switch self {
        case .map:           return "Item"
        case .organisations: return "Organisation"
        case .people:        return "Person"
        case .projects:      return "Project"
        case .opportunities: return "Opportunity"
        case .tags:          return "Tag"
        case .notes:         return "Note"
        }
    }
    var icon: String {
        switch self {
        case .map:           return "point.3.filled.connected.trianglepath.dotted"
        case .organisations: return "building.2"
        case .people:        return "person.2"
        case .projects:      return "folder"
        case .opportunities: return "chart.line.uptrend.xyaxis"
        case .tags:          return "tag"
        case .notes:         return "doc.text"
        }
    }
    var tint: Color {
        switch self {
        case .map:           return .purple
        case .organisations: return .blue
        case .people:        return .teal
        case .projects:      return .orange
        case .opportunities: return .green
        case .tags:          return .pink
        case .notes:         return .indigo
        }
    }
}

// MARK: Root

private struct CatalogView: View {
    @ObservedObject private var store = CatalogStore.shared
    @State private var section: CatalogSection = .organisations
    @State private var selID: String?
    @State private var status = ""
    @State private var showQuickAdd = false
    @State private var showPurge = false
    @State private var mapSection: CatalogSection?
    @State private var mapID: String?
    // Notes search + filters (in the window toolbar).
    @State private var query = ""
    @State private var fOrg = ""
    @State private var fProject = ""
    @State private var fOpp = ""
    @State private var fTag = ""
    @State private var fPerson = ""
    @State private var scope: NoteSearchScope = .text
    @State private var askNonce = 0
    private var anyFilter: Bool { !(fOrg.isEmpty && fProject.isEmpty && fOpp.isEmpty && fTag.isEmpty && fPerson.isEmpty) }
    private var canAsk: Bool { !AppSettings.shared.localOnlyMode && KeychainService.groqAPIKey() != nil }

    /// Notes matching the active facet filters (ignoring the query — in Ask mode
    /// the query is the question). These scope what Ask retrieves from.
    private var askFiles: [NotesLibrary.MeetingFile] {
        store.doc.notes.filter { n in
            (fOrg.isEmpty || store.effectiveOrgIDs(of: n).contains(fOrg))
            && (fProject.isEmpty || store.effectiveProjectIDs(of: n).contains(fProject))
            && (fOpp.isEmpty || n.opportunityIDs.contains(fOpp))
            && (fTag.isEmpty || n.tagIDs.contains(fTag))
            && (fPerson.isEmpty || {
                guard let p = store.person(fPerson) else { return false }
                return !store.effectiveOrgIDs(of: n).isDisjoint(with: Set(p.orgIDs))
            }())
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
        case .map:           return 0
        case .organisations: return store.doc.orgs.count
        case .people:        return store.doc.people.count
        case .projects:      return store.doc.projects.count
        case .opportunities: return store.doc.opportunities.count
        case .tags:          return store.doc.tags.count
        case .notes:         return store.doc.notes.count
        }
    }

    var body: some View {
        NavigationSplitView {
            List(CatalogSection.allCases, selection: $section) { s in
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
            .navigationSplitViewColumnWidth(min: 178, ideal: 192, max: 220)
            .safeAreaInset(edge: .bottom) { importFooter }
        } content: {
            contentColumn
                .navigationSplitViewColumnWidth(min: 240, ideal: 285, max: 400)
                .navigationTitle(section.rawValue)
        } detail: {
            if section == .map {
                if let sec = mapSection, let id = mapID {
                    EntityEditorView(store: store, section: sec, id: id) { mapID = nil }
                        .id(id)
                        .frame(minWidth: 340)
                } else {
                    ContentUnavailableView("Catalog map", systemImage: "point.3.filled.connected.trianglepath.dotted",
                                           description: Text("Expand the tree and pick any item to open it here."))
                }
            } else {
                EntityDetail(store: store, section: section, selID: $selID)
            }
        }
        .onChange(of: section) { _, _ in selID = nil; mapSection = nil; mapID = nil }
        .frame(minWidth: 820, minHeight: 500)
        .sheet(isPresented: $showQuickAdd) { QuickAddSheet(store: store) }
        .confirmationDialog("Purge the entire catalog?", isPresented: $showPurge, titleVisibility: .visible) {
            Button("Purge catalog", role: .destructive) {
                store.purgeAll(); selID = nil; mapSection = nil; mapID = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deletes every organisation, person, project, opportunity, tag and note link. Your Markdown note files are not touched. This cannot be undone.")
        }
    }

    @ViewBuilder private var contentColumn: some View {
        if section == .map {
            MapTree(store: store) { sec, id in mapSection = sec; mapID = id }
        } else if section == .notes {
            Group {
                if scope == .ask {
                    NoteAskView(store: store, question: query, nonce: askNonce,
                                files: askFiles, filterSummary: filterSummary) { selID = $0 }
                } else {
                    NotesList(store: store, selID: $selID, query: query, scope: scope,
                              fOrg: fOrg, fProject: fProject, fOpp: fOpp, fTag: fTag, fPerson: fPerson)
                }
            }
                .searchable(text: $query, placement: .toolbar,
                            prompt: scope == .ask ? "Ask a question…" : "Search notes")
                .onSubmit(of: .search) { if scope == .ask { askNonce += 1 } }
                .toolbar {
                    ToolbarItemGroup(placement: .automatic) {
                        facet("Org", "building.2", $fOrg, store.orgsSorted.map { ($0.id, store.orgPath(of: $0.id)) })
                        facet("Project", "folder", $fProject, store.doc.projects.sortedByName.map { ($0.id, $0.name) })
                        facet("Opp", "chart.line.uptrend.xyaxis", $fOpp, store.doc.opportunities.sortedByName.map { ($0.id, $0.name) })
                        facet("Person", "person", $fPerson, store.doc.people.sortedByName.map { ($0.id, $0.name) })
                        facet("Tag", "tag", $fTag, store.tagsSorted.map { ($0.id, $0.name) })
                        Button { fOrg = ""; fProject = ""; fOpp = ""; fTag = ""; fPerson = "" } label: {
                            Label("Reset", systemImage: "arrow.counterclockwise")
                        }
                        .disabled(!anyFilter)
                        .help("Reset all filters")
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Picker("Search type", selection: $scope) {
                            Label("Text", systemImage: "textformat").tag(NoteSearchScope.text)
                            if NotesLibrary.semanticAvailable {
                                Label("Meaning", systemImage: "brain").tag(NoteSearchScope.meaning)
                            }
                            if canAsk { Label("Ask", systemImage: "sparkles").tag(NoteSearchScope.ask) }
                        }
                        .pickerStyle(.segmented)
                        .help("Search type")
                    }
                }
        } else {
            EntityList(store: store, section: section, selID: $selID)
        }
    }

    /// A single filter as its own toolbar menu; tints + shows the value when set.
    private func facet(_ label: String, _ icon: String, _ sel: Binding<String>, _ options: [(String, String)]) -> some View {
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
        .help("Filter by \(label)")
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
                status = n > 0 ? "Imported \(n) note\(n == 1 ? "" : "s")" : "Up to date"
            } label: {
                Label("Import notes", systemImage: "arrow.down.doc").frame(maxWidth: .infinity)
            }
            .controlSize(.small)
            .help("Scan the notes folder and add meeting notes not yet in the catalog")
            Button(role: .destructive) { showPurge = true } label: {
                Label("Purge catalog…", systemImage: "trash").frame(maxWidth: .infinity)
            }
            .controlSize(.small)
            .help("Delete all catalog data (note files are kept)")
            if !status.isEmpty { Text(status).font(.caption2).foregroundStyle(.secondary) }
        }
        .padding(10)
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
        return store.projects(forOrg: id).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    private var oppsForProject: [CatalogOpportunity] {
        guard projSel != Self.new, !projSel.isEmpty else { return [] }
        return store.opportunities(forProject: projSel).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
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

        // People — attach chosen existing to the org, plus any new names.
        for pid in selectedPeople {
            if var p = store.person(pid), !p.orgIDs.contains(orgID) { p.orgIDs.append(orgID); store.update(p) }
        }
        for name in splitList(newPeople) {
            var p = store.addPerson(name: name); p.orgIDs = [orgID]; store.update(p)
        }

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

    var body: some View {
        Group {
            switch section {
            case .map:           EmptyView()   // handled by CatalogView
            case .organisations: orgList
            case .people:        List(store.doc.people.sortedByName, selection: $selID) { Text($0.name).tag($0.id) }
            case .projects:      projectList
            case .opportunities: oppList
            case .tags:          tagList
            case .notes:         EmptyView()   // handled by CatalogView
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
        return List(selection: $selID) {
            ForEach(rows(store.rootOrgs, 0), id: \.0.id) { org, depth in
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

    private var projectList: some View {
        List(store.doc.projects.sortedByName, selection: $selID) { p in
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
        List(store.doc.opportunities.sortedByName, selection: $selID) { o in
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
        List(store.tagsSorted, selection: $selID) { t in
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
        case .notes:         break
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
        case .map: EmptyView()
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

private struct RelationshipBadge: View {
    let rel: OrgRelationship
    init(_ r: OrgRelationship) { rel = r }
    var body: some View {
        Text(rel.label)
            .font(.caption2).fontWeight(.medium)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.16)))
            .foregroundStyle(color)
    }
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
    var body: some View {
        Text(stage.label)
            .font(.caption2).fontWeight(.medium)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.16)))
            .foregroundStyle(color)
    }
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
            let people = store.people(forOrg: draft.id)
            if !people.isEmpty { Section("People") { ForEach(people) { Text($0.name) } } }
            let projects = store.projects(forOrg: draft.id)
            if !projects.isEmpty { Section("Projects") { ForEach(projects) { Text($0.name) } } }
            let notes = store.notes(forOrg: draft.id, includingDescendants: true)
            if !notes.isEmpty { Section("Notes (incl. sub-orgs)") { ForEach(notes) { NoteRow(note: $0) } } }
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
            Section("Organisations") {
                if store.orgsSorted.isEmpty { Text("No organisations yet.").font(.caption).foregroundStyle(.secondary) }
                ForEach(store.orgsSorted) { org in
                    Toggle(store.orgPath(of: org.id), isOn: Binding(
                        get: { draft.orgIDs.contains(org.id) },
                        set: { on in
                            if on { if !draft.orgIDs.contains(org.id) { draft.orgIDs.append(org.id) } }
                            else { draft.orgIDs.removeAll { $0 == org.id } }
                            commit()
                        }))
                }
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
                Section("Notes") { ForEach(notes) { NoteRow(note: $0) } }
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
    @State private var semanticOrder: [String] = []

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }

    private func facetFiltered(_ notes: [CatalogNote]) -> [CatalogNote] {
        var ns = notes
        if !fOrg.isEmpty { ns = ns.filter { store.effectiveOrgIDs(of: $0).contains(fOrg) } }
        if !fProject.isEmpty { ns = ns.filter { store.effectiveProjectIDs(of: $0).contains(fProject) } }
        if !fOpp.isEmpty { ns = ns.filter { $0.opportunityIDs.contains(fOpp) } }
        if !fTag.isEmpty { ns = ns.filter { $0.tagIDs.contains(fTag) } }
        if !fPerson.isEmpty, let p = store.person(fPerson) {
            let orgs = Set(p.orgIDs)
            ns = ns.filter { !store.effectiveOrgIDs(of: $0).isDisjoint(with: orgs) }
        }
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
                    VStack(alignment: .leading, spacing: 2) {
                        Text(n.title).lineLimit(1)
                        HStack(spacing: 6) {
                            if let d = n.date { Text(d, style: .date) }
                            if !n.tagIDs.isEmpty { Text("· \(n.tagIDs.count) tags") }
                        }
                        .font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
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

// MARK: Note editor (opportunities/projects assignable; org/people inherited)

private struct NoteLinkEditor: View {
    @ObservedObject var store: CatalogStore
    let note: CatalogNote
    @State private var newToken = ""
    @State private var newTag = ""

    private var current: CatalogNote { store.note(id: note.id) ?? note }

    private func addTag() {
        let name = newTag.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let t = store.addTag(name: name)
        store.setTag(t.id, on: note.id, true)
        newTag = ""
    }

    var body: some View {
        Form {
            Section {
                Button { openNote(note) } label: { Label("Open note", systemImage: "arrow.up.forward.app") }
                if let d = note.date { LabeledContent("Date") { Text(d, style: .date) } }
            }

            // Assign to an opportunity (drives project → org → people) …
            Section("Opportunity") {
                let assigned = store.doc.opportunities.filter { current.opportunityIDs.contains($0.id) }
                ForEach(assigned) { o in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(o.name)
                            Text(oppPath(o)).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { store.setOpportunity(o.id, on: note.id, false) } label: {
                            Image(systemName: "minus.circle.fill")
                        }.buttonStyle(.plain).foregroundStyle(.red.opacity(0.8))
                    }
                }
                let unassigned = store.doc.opportunities.sortedByName.filter { !current.opportunityIDs.contains($0.id) }
                Menu {
                    if unassigned.isEmpty { Text("No more opportunities") }
                    ForEach(unassigned) { o in
                        Button(oppPath(o).isEmpty ? o.name : "\(oppPath(o)) › \(o.name)") {
                            store.setOpportunity(o.id, on: note.id, true)
                        }
                    }
                } label: { Label("Assign opportunity", systemImage: "plus.circle") }
                    .disabled(store.doc.opportunities.isEmpty || !current.orgIDs.isEmpty)
                if !current.orgIDs.isEmpty {
                    Text("This note is assigned to an organisation. Remove it to assign an opportunity instead.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if store.doc.opportunities.isEmpty {
                    Text("No opportunities yet — create one from a note token below or the Opportunities tab.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            // … or, for an internal note with no opportunity, assign an org directly.
            Section("Organisation") {
                let direct = store.orgsSorted.filter { current.orgIDs.contains($0.id) }
                ForEach(direct) { o in
                    HStack {
                        Text(store.orgPath(of: o.id))
                        Spacer()
                        Button { store.setOrg(o.id, on: note.id, false) } label: {
                            Image(systemName: "minus.circle.fill")
                        }.buttonStyle(.plain).foregroundStyle(.red.opacity(0.8))
                    }
                }
                // Orgs reaching the note via an opportunity (read-only).
                let viaOpp = store.effectiveOrgIDs(of: current).subtracting(current.orgIDs)
                ForEach(store.orgsSorted.filter { viaOpp.contains($0.id) }) { o in
                    HStack {
                        Text(store.orgPath(of: o.id)).foregroundStyle(.secondary)
                        Spacer()
                        Text("via opportunity").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                let assignable = store.orgsSorted.filter { !current.orgIDs.contains($0.id) }
                Menu {
                    if assignable.isEmpty { Text("No organisations") }
                    ForEach(assignable) { o in
                        Button(store.orgPath(of: o.id)) { store.setOrg(o.id, on: note.id, true) }
                    }
                } label: { Label("Assign organisation", systemImage: "plus.circle") }
                    .disabled(store.orgsSorted.isEmpty || !current.opportunityIDs.isEmpty)
                if !current.opportunityIDs.isEmpty {
                    Text("This note is assigned to an opportunity (org comes from it). Remove it to set an org directly.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            let projIDs = store.effectiveProjectIDs(of: current)
            if !projIDs.isEmpty {
                Section("Projects (inherited)") {
                    ForEach(store.doc.projects.sortedByName.filter { projIDs.contains($0.id) }) { Text($0.name) }
                }
            }
            let people = store.inheritedPeople(of: current)
            if !people.isEmpty {
                Section("People (inherited)") { ForEach(people) { Text($0.name) } }
            }

            Section("Tags") {
                HStack {
                    TextField("New tag", text: $newTag).textFieldStyle(.roundedBorder).onSubmit(addTag)
                    Button(action: addTag) { Image(systemName: "plus") }
                        .disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(store.tagsSorted) { tag in
                            Toggle(tag.name, isOn: Binding(
                                get: { current.tagIDs.contains(tag.id) },
                                set: { store.setTag(tag.id, on: note.id, $0) }))
                        }
                    }
                }
                .frame(height: store.tagsSorted.count > 6 ? 150 : nil)
            }

            // Action items (all shown; the form scrolls).
            NoteActionItemsSection(url: store.url(of: current))

            // Promotion tools last.
            Section("Add from this note") {
                HStack {
                    TextField("Type a word…", text: $newToken).textFieldStyle(.roundedBorder)
                    PromoteMenu(store: store, noteID: note.id, token: newToken.trimmingCharacters(in: .whitespaces)) { newToken = "" }
                        .disabled(newToken.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                let suggestions = store.suggestedTags(for: current)
                if !suggestions.isEmpty {
                    Text("Suggested from the note").font(.caption).foregroundStyle(.secondary)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(suggestions, id: \.self) { token in
                                HStack {
                                    Text(token)
                                    Spacer()
                                    PromoteMenu(store: store, noteID: note.id, token: token) {}
                                }
                            }
                        }
                    }
                    .frame(height: suggestions.count > 6 ? 160 : nil)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(note.title)
    }

    private func hint(_ what: String) -> some View {
        Text("No \(what) yet — add one below.").font(.caption).foregroundStyle(.secondary)
    }
    private var inheritedHint: some View {
        Text("Assign an opportunity above.").font(.caption).foregroundStyle(.secondary)
    }
    /// "Org › Project" context for an opportunity.
    private func oppPath(_ o: CatalogOpportunity) -> String {
        var parts: [String] = []
        if let p = store.project(o.projectID) {
            if let org = store.org(p.orgID) { parts.append(store.orgPath(of: org.id)) }
            parts.append(p.name)
        }
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
            Label("Add as", systemImage: "plus.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func addPerson() {
        var p = store.addPerson(name: token)
        if let n = note { p.orgIDs = Array(store.effectiveOrgIDs(of: n)) }   // attach to note's orgs → shows as inherited
        store.update(p)
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

private struct MapTree: View {
    @ObservedObject var store: CatalogStore
    let onPick: MapPick
    @State private var search = ""

    private var q: String { search.trimmingCharacters(in: .whitespaces).lowercased() }

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
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            Divider()
            List {
                if store.doc.orgs.isEmpty && store.doc.projects.isEmpty {
                    Text("Nothing to map yet — add organisations, or import notes.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(rootOrgs) { OrgMapNode(store: store, org: $0, onPick: onPick) }
                if !orphanProjects.isEmpty {
                    Section("No organisation") {
                        ForEach(orphanProjects) { ProjectMapNode(store: store, project: $0, onPick: onPick) }
                    }
                }
            }
        }
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
    let onPick: MapPick
    var body: some View {
        DisclosureGroup {
            ForEach(store.childOrgs(of: org.id)) { OrgMapNode(store: store, org: $0, onPick: onPick) }
            ForEach(store.projects(forOrg: org.id)) { ProjectMapNode(store: store, project: $0, onPick: onPick) }
            ForEach(store.people(forOrg: org.id)) { p in
                MapRow(icon: "person", tint: .teal, title: p.name) { onPick(.people, p.id) }
            }
            // Internal notes attached directly to this org (no opportunity).
            ForEach(store.notes(directlyOnOrg: org.id)) { n in
                MapRow(icon: "doc.text", tint: .indigo, title: n.title, openIcon: "arrow.up.forward.app") { openNote(n) }
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
    let onPick: MapPick
    var body: some View {
        DisclosureGroup {
            let opps = store.opportunities(forProject: project.id)
            if opps.isEmpty { Text("No opportunities").font(.caption2).foregroundStyle(.secondary) }
            ForEach(opps) { OppMapNode(store: store, opp: $0, onPick: onPick) }
        } label: {
            MapRow(icon: "folder", tint: .orange, title: project.name) { onPick(.projects, project.id) }
        }
    }
}

private struct OppMapNode: View {
    @ObservedObject var store: CatalogStore
    let opp: CatalogOpportunity
    let onPick: MapPick
    var body: some View {
        DisclosureGroup {
            let notes = store.notes(forOpportunity: opp)
            if notes.isEmpty { Text("No notes").font(.caption2).foregroundStyle(.secondary) }
            ForEach(notes) { n in
                MapRow(icon: "doc.text", tint: .indigo, title: n.title, openIcon: "arrow.up.forward.app") { openNote(n) }
            }
        } label: {
            MapRow(icon: "chart.line.uptrend.xyaxis", tint: .green, title: opp.name,
                   trailing: AnyView(StageBadge(opp.stage))) { onPick(.opportunities, opp.id) }
        }
    }
}

// MARK: Sorting + small helpers

private extension Array where Element == CatalogPerson {
    var sortedByName: [CatalogPerson] { sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } }
}
private extension Array where Element == CatalogProject {
    var sortedByName: [CatalogProject] { sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } }
}
private extension Array where Element == CatalogOpportunity {
    var sortedByName: [CatalogOpportunity] { sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } }
}

private func splitList(_ s: String) -> [String] {
    s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
}
