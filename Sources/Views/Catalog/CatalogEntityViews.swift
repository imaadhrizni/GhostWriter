import SwiftUI
import AppKit
import UniformTypeIdentifiers

// Entity master-list, detail, editors and bulk sheets — extracted from
// CatalogWindow.swift to keep the window shell focused on navigation.

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
            let subtitle = [p.designation, p.email].compactMap { $0 }.first
            VStack(alignment: .leading, spacing: 1) {
                Text(p.name)
                if let subtitle {
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.leading, CGFloat(depth) * 14).tag(p.id)
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
                TextField("Designation", text: Binding(
                    get: { draft.designation ?? "" },
                    set: { draft.designation = $0.isEmpty ? nil : $0 })).onSubmit(commit)
                TextField("Email", text: Binding(
                    get: { draft.email ?? "" },
                    set: { draft.email = $0.isEmpty ? nil : $0 })).onSubmit(commit)
                TextField("Phone", text: Binding(
                    get: { draft.phone ?? "" },
                    set: { draft.phone = $0.isEmpty ? nil : $0 })).onSubmit(commit)
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

/// Paste-many creator for People or Tags. Tags take one name per line; People
/// take one person per line with optional **Name, Email, Phone, Designation**
/// columns (comma- or tab-separated — tab-separated pastes straight from a
/// spreadsheet), an optional type applied to all created rows. Existing names
/// are skipped, so the sheet is safe to reuse.
struct BulkAddSheet: View {
    @ObservedObject var store: CatalogStore
    let section: CatalogSection
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var typeID: String? = nil

    private var isPeople: Bool { section == .people }
    private var noun: String { isPeople ? "People" : "Tags" }

    /// Tag names — one per line.
    private var tagNames: [String] {
        text.split(whereSeparator: \.isNewline).map(String.init)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// People parsed from `Name, Email, Phone, Designation` columns. A line is
    /// split on tab when it contains one (spreadsheet paste), else on comma;
    /// only the name is required.
    private var people: [CatalogPerson] {
        text.split(whereSeparator: \.isNewline).compactMap { line -> CatalogPerson? in
            let raw = String(line)
            let sep: Character = raw.contains("\t") ? "\t" : ","
            let cols = raw.split(separator: sep, omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard let name = cols.first, !name.isEmpty else { return nil }
            var p = CatalogPerson(name: name)
            p.typeID = typeID
            func col(_ i: Int) -> String? { cols.count > i && !cols[i].isEmpty ? cols[i] : nil }
            p.email = col(1); p.phone = col(2); p.designation = col(3)
            return p
        }
    }

    private var count: Int { isPeople ? people.count : tagNames.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Bulk Add \(noun)").font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding()
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text(isPeople
                     ? "One person per line: **Name, Email, Phone, Designation** — comma- or tab-separated (paste from a spreadsheet). Only Name is required."
                     : "One name per line.")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $text)
                    .font(.body.monospaced())
                    .frame(minHeight: 180)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                if isPeople {
                    LabeledContent("Type for all") {
                        PersonTypePicker(store: store, selection: $typeID)
                    }
                }
            }.padding()
            Divider()
            HStack {
                Text(isPeople ? "\(count) \(count == 1 ? "person" : "people")"
                              : "\(count) name\(count == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Add") {
                    if isPeople { store.addPeople(people) }
                    else { store.addTags(names: tagNames) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction).disabled(count == 0)
            }.padding()
        }
        .frame(width: 480, height: 440)
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
