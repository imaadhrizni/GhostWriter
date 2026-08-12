import Foundation

// Extracted from Catalog.swift to keep CatalogStore readable. Behavior is
// unchanged — these are the same members, just grouped by concern.

// MARK: - CatalogStore · Graph lookups & derivation

extension CatalogStore {
    // MARK: Lookups

    func org(_ id: String?) -> CatalogOrg? { doc.orgs.first { $0.id == id } }
    func project(_ id: String?) -> CatalogProject? { doc.projects.first { $0.id == id } }
    func tag(_ id: String?) -> CatalogTag? { doc.tags.first { $0.id == id } }
    func person(_ id: String?) -> CatalogPerson? { doc.people.first { $0.id == id } }

    var orgsSorted: [CatalogOrg] { doc.orgs.sortedByName }
    var tagsSorted: [CatalogTag] { doc.tags.sortedByName }

    func orgs(relationship: OrgRelationship) -> [CatalogOrg] {
        orgsSorted.filter { $0.relationship == relationship }
    }

    // Org hierarchy (unlimited depth).
    var rootOrgs: [CatalogOrg] { orgsSorted.filter { $0.parentID == nil || org($0.parentID) == nil } }
    func childOrgs(of id: String) -> [CatalogOrg] { orgsSorted.filter { $0.parentID == id } }

    /// `id` plus every ancestor, nearest first. Guards against broken/looping links.
    func orgLineage(of id: String) -> [String] {
        Self.lineage(of: id, exists: { org($0) != nil }, parentOf: { org($0)?.parentID })
    }
    /// `id` plus all descendants (for cycle-safe parent choices and subtree filters).
    func orgSubtree(of id: String) -> Set<String> {
        Self.subtree(of: id, children: { childOrgs(of: $0).map(\.id) })
    }

    /// Shared hierarchy walkers for the two parallel org/project trees. Both are
    /// cycle-safe (a `seen`/visited set stops broken or looping parent links).
    static func lineage(of id: String, exists: (String) -> Bool, parentOf: (String) -> String?) -> [String] {
        var chain: [String] = [], cur: String? = id, seen = Set<String>()
        while let c = cur, seen.insert(c).inserted, exists(c) {
            chain.append(c); cur = parentOf(c)
        }
        return chain
    }
    static func subtree(of id: String, children: (String) -> [String]) -> Set<String> {
        var out: Set<String> = [id], stack = [id]
        while let cur = stack.popLast() {
            for child in children(cur) where out.insert(child).inserted { stack.append(child) }
        }
        return out
    }
    /// "Group › Company › Division" for display.
    func orgPath(of id: String) -> String {
        orgLineage(of: id).reversed().compactMap { org($0)?.name }.joined(separator: " › ")
    }

    // Project hierarchy (unlimited depth), mirroring orgs.
    var projectsSorted: [CatalogProject] { doc.projects.sortedByName }
    var rootProjects: [CatalogProject] { projectsSorted.filter { $0.parentID == nil || project($0.parentID) == nil } }
    func childProjects(of id: String) -> [CatalogProject] { projectsSorted.filter { $0.parentID == id } }
    /// `id` plus every ancestor project, nearest first. Cycle-safe.
    func projectLineage(of id: String) -> [String] {
        Self.lineage(of: id, exists: { project($0) != nil }, parentOf: { project($0)?.parentID })
    }
    /// `id` plus all descendant projects.
    func projectSubtree(of id: String) -> Set<String> {
        Self.subtree(of: id, children: { childProjects(of: $0).map(\.id) })
    }
    /// A project's org, resolved by walking up the project hierarchy to the
    /// first ancestor that carries an orgID.
    func org(forProject id: String) -> CatalogOrg? {
        for pid in projectLineage(of: id) { if let o = project(pid)?.orgID { return org(o) } }
        return nil
    }
    /// "Acme › Platform › Phase 2" — org path then the project lineage.
    func projectPath(of id: String) -> String {
        let projNames = projectLineage(of: id).reversed().compactMap { project($0)?.name }
        let orgPart = org(forProject: id).map { orgPath(of: $0.id) }
        return ([orgPart].compactMap { $0 } + projNames).joined(separator: " › ")
    }

    /// Which entities a tree picker offers, so one component serves every
    /// chooser in the app: both (Assign / Ask / import), orgs only (an org's
    /// parent, a project's org), or projects only (a project's parent — orgs
    /// still shown for context but not selectable).
    enum TreeScope { case both, orgsOnly, projectsOnly }

    /// A flattened org→project tree for pickers: every org (nested), each org's
    /// root projects and their sub-projects, then any orphan projects — with the
    /// indent depth so callers can render one consistent tree everywhere. Rows
    /// that don't match `scope` come back `selectable == false` (dimmed context).
    /// `excluding` drops an id and its subtree (a parent picker excludes itself).
    /// When `query` is non-empty the tree collapses to a flat, depth-0 match list
    /// of selectable rows only.
    struct TreeRow: Identifiable {
        public let id: String; public let kind: String; public let name: String
        public let depth: Int; public let selectable: Bool
    }
    func orgProjectRows(matching query: String = "",
                        scope: TreeScope = .both,
                        excluding: Set<String> = []) -> [TreeRow] {
        var out: [TreeRow] = []
        let includeProjects = scope != .orgsOnly
        let orgsSelectable = scope != .projectsOnly
        func walkProject(_ p: CatalogProject, _ depth: Int) {
            if excluding.contains(p.id) { return }
            out.append(TreeRow(id: p.id, kind: "project", name: p.name, depth: depth, selectable: true))
            for c in childProjects(of: p.id) { walkProject(c, depth + 1) }
        }
        func walkOrg(_ o: CatalogOrg, _ depth: Int) {
            if excluding.contains(o.id) { return }
            out.append(TreeRow(id: o.id, kind: "org", name: o.name, depth: depth, selectable: orgsSelectable))
            for c in childOrgs(of: o.id) { walkOrg(c, depth + 1) }
            if includeProjects { for p in rootProjects(forOrg: o.id) { walkProject(p, depth + 1) } }
        }
        for root in rootOrgs { walkOrg(root, 0) }
        // Orphan root projects (no org, no parent) so nothing is unreachable.
        if includeProjects {
            for p in projectsSorted where p.parentID == nil && org(forProject: p.id) == nil {
                walkProject(p, 0)
            }
        }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return out }
        return out.filter { $0.selectable && $0.name.lowercased().contains(q) }
            .map { TreeRow(id: $0.id, kind: $0.kind, name: $0.name, depth: 0, selectable: true) }
    }

    /// A note's projects: those directly assigned plus their ancestor projects.
    func effectiveProjectIDs(of note: CatalogNote) -> Set<String> {
        var s = Set<String>()
        for pid in note.projectIDs { s.formUnion(projectLineage(of: pid)) }
        return s
    }
    /// A note's orgs, derived up the chain (project → parent projects → org).
    func effectiveOrgIDs(of note: CatalogNote) -> Set<String> {
        var s = Set(note.orgIDs)
        for pid in effectiveProjectIDs(of: note) { if let o = project(pid)?.orgID { s.insert(o) } }
        return s
    }
    /// A note with no link at all — not on any project and not directly on any
    /// org, so it doesn't surface anywhere in the map. These are the ones worth
    /// triaging into a project or an org.
    func isUnassigned(_ note: CatalogNote) -> Bool {
        note.projectIDs.isEmpty && note.orgIDs.isEmpty
    }
    var unassignedNotes: [CatalogNote] { doc.notes.filter(isUnassigned) }

    /// Notes filed under a project (directly or under a descendant project).
    func notes(forProject id: String) -> [CatalogNote] {
        let subtree = projectSubtree(of: id)
        return doc.notes.filter { !effectiveProjectIDs(of: $0).isDisjoint(with: subtree) }
    }

    /// The catalog link chain for a note file — its linked project / org names
    /// (resolved as one consistent chain, deepest link first) plus the project's
    /// POC criteria. Shared by the notes-viewer PDF export and the Follow-Up
    /// Packet so the resolution lives in one place.
    func linkChain(forFileURL fileURL: URL)
        -> (org: String?, project: String?, criteria: [PocCriterion]) {
        guard let note = doc.notes.first(where: {
            url(of: $0).standardizedFileURL == fileURL.standardizedFileURL
        }) else { return (nil, nil, []) }

        if let projID = note.projectIDs.first, let proj = project(projID) {
            return (org(forProject: proj.id)?.name, proj.name, proj.pocs.flatMap(\.criteria))
        }
        if let orgID = note.orgIDs.first {
            return (org(orgID)?.name, nil, [])
        }
        return (nil, nil, [])
    }
    /// Notes assigned *directly* to an org (internal notes with no project).
    func notes(directlyOnOrg id: String) -> [CatalogNote] {
        doc.notes.filter { $0.orgIDs.contains(id) }
    }

    func notes(forOrg id: String, includingDescendants: Bool = false) -> [CatalogNote] {
        let ids: Set<String> = includingDescendants ? orgSubtree(of: id) : [id]
        return doc.notes.filter { !effectiveOrgIDs(of: $0).isDisjoint(with: ids) }
    }
    func notes(forTag id: String) -> [CatalogNote] {
        doc.notes.filter { $0.tagIDs.contains(id) }
    }
    func projects(forOrg id: String) -> [CatalogProject] {
        doc.projects.filter { $0.orgID == id }
    }
    /// An org's **top-level** projects (no parent project) — its roots in the
    /// project hierarchy. Sub-projects inherit the org through their parent and
    /// are reached via `childProjects`, so they aren't listed here.
    func rootProjects(forOrg id: String) -> [CatalogProject] {
        doc.projects.filter { $0.parentID == nil && $0.orgID == id }.sortedByName
    }
    /// People are independent of orgs; an org's people are simply whoever
    /// appears on its notes. An org with no notes contributes nobody, mirroring
    /// how tags surface only where there's note activity.
    func peopleFromNotes(forOrg id: String) -> [CatalogPerson] {
        var ids = Set<String>()
        for n in notes(forOrg: id) { ids.formUnion(n.personIDs) }
        return doc.people.filter { ids.contains($0.id) }.sortedByName
    }
    /// Notes a person appears on directly.
    func notes(forPerson id: String) -> [CatalogNote] {
        doc.notes.filter { $0.personIDs.contains(id) }
    }
    /// A note's own people (the ones attributed directly to it).
    func people(of note: CatalogNote) -> [CatalogPerson] {
        doc.people.filter { note.personIDs.contains($0.id) }.sortedByName
    }
    /// A note's own tags.
    func tags(of note: CatalogNote) -> [CatalogTag] {
        doc.tags.filter { note.tagIDs.contains($0.id) }.sortedByName
    }
}
