import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Catalog · Map tree

typealias MapPick = (CatalogSection, String) -> Void

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
struct MapFilter {
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

struct MapTree: View {
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
struct MapRow: View {
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

struct OrgMapNode: View {
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

struct ProjectMapNode: View {
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
struct NoteMapNode: View {
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
