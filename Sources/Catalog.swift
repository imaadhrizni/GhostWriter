import Foundation
import Combine

// MARK: - Catalog
//
// A lightweight organiser that sits *beside* the Markdown notes without
// touching them: a graph of the people, organisations, projects, opportunities
// and tags your meetings are about, plus the links from each note to those
// entities. The notes stay the source of truth for content; this catalog is
// the source of truth for structure and manual tagging.
//
// Storage is a single Codable JSON document (`Catalog.json`) in the notes
// folder, so it rides along with the user's existing backup/sync and can be
// deleted without ever risking a note. (A SQLite backing store could later be
// swapped in behind `CatalogStore` — the model and API would not change.)

// MARK: Entities

/// How an organisation relates to you. Set once per org and inherited by all
/// its meetings — never inferred from a single conversation.
enum OrgRelationship: String, Codable, CaseIterable, Identifiable {
    case root, customer, prospect, partner, internalOrg = "internal", other
    var id: String { rawValue }
    var label: String {
        switch self {
        case .root:        return "Root"
        case .customer:    return "Customer"
        case .prospect:    return "Prospect"
        case .partner:     return "Partner"
        case .internalOrg: return "Internal"
        case .other:       return "Other"
        }
    }
}

struct CatalogOrg: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var name: String
    /// Parent org — nil for a root. Supports an unlimited hierarchy
    /// (Group › Company › Division › …). Cycles are prevented on assignment.
    var parentID: String?
    var relationship: OrgRelationship = .root
    var isInternal = false
    /// Spoken/company names that resolve to this org (the audio "learn-once"
    /// identity map; also usable for manual matching). Lowercased on match.
    var aliases: [String] = []
    var notes = ""
}

struct CatalogPerson: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var name: String
    /// Which side of the call they came from, when known.
    var channel: String?      // "internal" | "external"
    /// A person can belong to several orgs (org ↔ people is many-to-many).
    var orgIDs: [String] = []
    var email: String?
}

struct CatalogProject: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var name: String
    var orgID: String?
    var archived = false
}

enum OppStage: String, Codable, CaseIterable, Identifiable {
    case open, won, lost
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

struct CatalogOpportunity: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var name: String
    /// Owning project (project → opportunities is one-to-many). The org is
    /// derived from the project — opportunities are never assigned an org
    /// directly, since the project already carries it.
    var projectID: String?
    var stage: OppStage = .open
    var valueCents: Int?
    var currency = "USD"
}

/// Controlled-vocabulary tag. Aliases fold variants (renewal/renewals) into one.
struct CatalogTag: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var name: String
    var aliases: [String] = []
}

/// A note's row in the catalog. Ties to the file by relative path; carries all
/// the links (many-to-many) to entities and tags.
struct CatalogNote: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var filePath: String          // relative to the notes folder
    var title: String
    var date: Date?
    var kind: String = "meeting"
    /// Notes are assigned to opportunities (and/or projects) and tags. The rest
    /// of the chain — project → org → people — is inherited automatically.
    /// `orgIDs` is retained for legacy direct links but no longer set from the UI.
    var opportunityIDs: [String] = []
    var projectIDs: [String] = []
    var orgIDs: [String] = []
    var tagIDs: [String] = []
}

// MARK: Document

/// The whole catalog, serialised as one JSON file.
struct CatalogDocument: Codable {
    var schemaVersion = 1
    var orgs: [CatalogOrg] = []
    var people: [CatalogPerson] = []
    var projects: [CatalogProject] = []
    var opportunities: [CatalogOpportunity] = []
    var tags: [CatalogTag] = []
    var notes: [CatalogNote] = []
}

// MARK: Store

/// Owns the catalog document, persists it, and exposes CRUD + queries.
/// `@MainActor` because it's an `ObservableObject` driving the Catalog window.
@MainActor
final class CatalogStore: ObservableObject {
    static let shared = CatalogStore()

    @Published private(set) var doc = CatalogDocument()

    private var fileURL: URL {
        AppSettings.shared.notesFolder.appendingPathComponent("Catalog.json")
    }

    init() { load() }

    // MARK: Persistence

    func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601   // must match the encoder, or decode throws → data "vanishes"
        guard let decoded = try? decoder.decode(CatalogDocument.self, from: data) else { return }
        doc = decoded
    }

    private func save() {
        let dir = AppSettings.shared.notesFolder
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(doc) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Route every mutation through here so persistence is never forgotten.
    private func mutate(_ change: (inout CatalogDocument) -> Void) {
        objectWillChange.send()
        change(&doc)
        save()
    }

    /// Wipe the entire catalog (orgs, people, projects, opportunities, tags,
    /// note links). Does not touch the Markdown note files themselves.
    func purgeAll() {
        mutate { $0 = CatalogDocument() }
    }

    // MARK: Lookups

    func org(_ id: String?) -> CatalogOrg? { doc.orgs.first { $0.id == id } }
    func project(_ id: String?) -> CatalogProject? { doc.projects.first { $0.id == id } }
    func tag(_ id: String?) -> CatalogTag? { doc.tags.first { $0.id == id } }
    func person(_ id: String?) -> CatalogPerson? { doc.people.first { $0.id == id } }

    func opportunity(_ id: String?) -> CatalogOpportunity? { doc.opportunities.first { $0.id == id } }

    var orgsSorted: [CatalogOrg] { doc.orgs.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } }
    var tagsSorted: [CatalogTag] { doc.tags.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } }

    func orgs(relationship: OrgRelationship) -> [CatalogOrg] {
        orgsSorted.filter { $0.relationship == relationship }
    }

    // Org hierarchy (unlimited depth).
    var rootOrgs: [CatalogOrg] { orgsSorted.filter { $0.parentID == nil || org($0.parentID) == nil } }
    func childOrgs(of id: String) -> [CatalogOrg] { orgsSorted.filter { $0.parentID == id } }

    /// `id` plus every ancestor, nearest first. Guards against broken/looping links.
    func orgLineage(of id: String) -> [String] {
        var chain: [String] = [], cur: String? = id, seen = Set<String>()
        while let c = cur, seen.insert(c).inserted, org(c) != nil {
            chain.append(c); cur = org(c)?.parentID
        }
        return chain
    }
    /// `id` plus all descendants (for cycle-safe parent choices and subtree filters).
    func orgSubtree(of id: String) -> Set<String> {
        var out: Set<String> = [id], stack = [id]
        while let cur = stack.popLast() {
            for child in childOrgs(of: cur) where out.insert(child.id).inserted { stack.append(child.id) }
        }
        return out
    }
    /// "Group › Company › Division" for display.
    func orgPath(of id: String) -> String {
        orgLineage(of: id).reversed().compactMap { org($0)?.name }.joined(separator: " › ")
    }

    /// A note's projects: directly assigned plus those from its opportunities.
    func effectiveProjectIDs(of note: CatalogNote) -> Set<String> {
        var s = Set(note.projectIDs)
        for oid in note.opportunityIDs { if let p = opportunity(oid)?.projectID { s.insert(p) } }
        return s
    }
    /// A note's orgs, derived up the chain (opportunity → project → org).
    func effectiveOrgIDs(of note: CatalogNote) -> Set<String> {
        var s = Set(note.orgIDs)
        for pid in effectiveProjectIDs(of: note) { if let o = project(pid)?.orgID { s.insert(o) } }
        return s
    }
    /// People a note inherits via its (effective) orgs.
    func inheritedPeople(of note: CatalogNote) -> [CatalogPerson] {
        let orgs = effectiveOrgIDs(of: note)
        return doc.people.filter { !Set($0.orgIDs).isDisjoint(with: orgs) }
    }
    /// A note with no link at all — not on any opportunity and not directly on
    /// any org, so it doesn't surface anywhere in the map. These are the ones
    /// worth triaging into an opportunity or an org.
    func isUnassigned(_ note: CatalogNote) -> Bool {
        note.opportunityIDs.isEmpty && effectiveOrgIDs(of: note).isEmpty
    }
    var unassignedNotes: [CatalogNote] { doc.notes.filter(isUnassigned) }

    /// Notes assigned to an opportunity.
    func notes(forOpportunity o: CatalogOpportunity) -> [CatalogNote] {
        doc.notes.filter { $0.opportunityIDs.contains(o.id) }
    }
    /// Notes assigned *directly* to an org (internal notes with no opportunity).
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
    func opportunities(forProject id: String) -> [CatalogOpportunity] {
        doc.opportunities.filter { $0.projectID == id }
    }
    func opportunities(forOrg id: String) -> [CatalogOpportunity] {
        let projs = Set(projects(forOrg: id).map { $0.id })
        return doc.opportunities.filter { $0.projectID.map { projs.contains($0) } ?? false }
    }
    /// An opportunity's org, resolved through its project.
    func org(forOpportunity o: CatalogOpportunity) -> CatalogOrg? {
        project(o.projectID).flatMap { org($0.orgID) }
    }
    func people(forOrg id: String) -> [CatalogPerson] {
        doc.people.filter { $0.orgIDs.contains(id) }
    }

    // MARK: Org CRUD

    @discardableResult
    func addOrg(name: String, relationship: OrgRelationship = .root) -> CatalogOrg {
        var o = CatalogOrg(name: name, relationship: relationship)
        o.isInternal = (relationship == .internalOrg)
        mutate { $0.orgs.append(o) }
        return o
    }
    func update(_ org: CatalogOrg) {
        var o = org
        // Reject a parent that would create a cycle (self or a descendant).
        if let p = o.parentID, orgSubtree(of: o.id).contains(p) { o.parentID = nil }
        o.isInternal = (o.relationship == .internalOrg)
        mutate { doc in
            if let i = doc.orgs.firstIndex(where: { $0.id == o.id }) { doc.orgs[i] = o }
        }
    }
    func deleteOrg(_ id: String) {
        mutate { doc in
            let projIDs = Set(doc.projects.filter { $0.orgID == id }.map { $0.id })
            let oppIDs = Set(doc.opportunities.filter { projIDs.contains($0.projectID ?? "") }.map { $0.id })
            doc.orgs.removeAll { $0.id == id }
            for i in doc.orgs.indices where doc.orgs[i].parentID == id { doc.orgs[i].parentID = nil } // reparent to root
            doc.projects.removeAll { projIDs.contains($0.id) }          // cascade projects
            doc.opportunities.removeAll { oppIDs.contains($0.id) }      // …and their opps
            for i in doc.people.indices { doc.people[i].orgIDs.removeAll { $0 == id } }
            for i in doc.notes.indices {
                doc.notes[i].orgIDs.removeAll { $0 == id }
                doc.notes[i].projectIDs.removeAll { projIDs.contains($0) }
                doc.notes[i].opportunityIDs.removeAll { oppIDs.contains($0) }
            }
        }
    }
    /// Valid parents for an org: everything except itself and its descendants.
    func parentChoices(for id: String) -> [CatalogOrg] {
        let banned = orgSubtree(of: id)
        return orgsSorted.filter { !banned.contains($0.id) }
    }

    /// Find an org whose name or alias matches a spoken/typed name (case-insensitive).
    func matchOrg(name: String) -> CatalogOrg? {
        let n = name.lowercased()
        return doc.orgs.first { $0.name.lowercased() == n || $0.aliases.contains { $0.lowercased() == n } }
    }

    // MARK: Person / Project / Opportunity / Tag CRUD

    @discardableResult
    func addPerson(name: String) -> CatalogPerson {
        let p = CatalogPerson(name: name)
        mutate { $0.people.append(p) }
        return p
    }
    func update(_ p: CatalogPerson) {
        mutate { doc in if let i = doc.people.firstIndex(where: { $0.id == p.id }) { doc.people[i] = p } }
    }
    func deletePerson(_ id: String) {
        mutate { doc in doc.people.removeAll { $0.id == id } }
    }

    @discardableResult
    func addProject(name: String, orgID: String? = nil) -> CatalogProject {
        let p = CatalogProject(name: name, orgID: orgID)
        mutate { $0.projects.append(p) }
        return p
    }
    func update(_ p: CatalogProject) {
        mutate { doc in if let i = doc.projects.firstIndex(where: { $0.id == p.id }) { doc.projects[i] = p } }
    }
    func deleteProject(_ id: String) {
        mutate { doc in
            let oppIDs = Set(doc.opportunities.filter { $0.projectID == id }.map { $0.id })
            doc.projects.removeAll { $0.id == id }
            doc.opportunities.removeAll { oppIDs.contains($0.id) }   // cascade opps
            for i in doc.notes.indices {
                doc.notes[i].projectIDs.removeAll { $0 == id }
                doc.notes[i].opportunityIDs.removeAll { oppIDs.contains($0) }
            }
        }
    }

    @discardableResult
    func addOpportunity(name: String, projectID: String? = nil) -> CatalogOpportunity {
        let o = CatalogOpportunity(name: name, projectID: projectID)
        mutate { $0.opportunities.append(o) }
        return o
    }
    func update(_ o: CatalogOpportunity) {
        mutate { doc in if let i = doc.opportunities.firstIndex(where: { $0.id == o.id }) { doc.opportunities[i] = o } }
    }
    func deleteOpportunity(_ id: String) {
        mutate { doc in
            doc.opportunities.removeAll { $0.id == id }
            for i in doc.notes.indices { doc.notes[i].opportunityIDs.removeAll { $0 == id } }
        }
    }

    /// Add a tag, folding onto an existing one by name/alias if it already exists.
    @discardableResult
    func addTag(name: String) -> CatalogTag {
        let n = name.trimmingCharacters(in: .whitespaces)
        if let existing = doc.tags.first(where: {
            $0.name.lowercased() == n.lowercased() || $0.aliases.contains { $0.lowercased() == n.lowercased() }
        }) { return existing }
        let t = CatalogTag(name: n)
        mutate { $0.tags.append(t) }
        return t
    }
    func update(_ t: CatalogTag) {
        mutate { doc in if let i = doc.tags.firstIndex(where: { $0.id == t.id }) { doc.tags[i] = t } }
    }
    func deleteTag(_ id: String) {
        mutate { doc in
            doc.tags.removeAll { $0.id == id }
            for i in doc.notes.indices { doc.notes[i].tagIDs.removeAll { $0 == id } }
        }
    }
    /// Merge `sourceID` into `targetID`: retag every note, keep the source's
    /// name as an alias, then drop the source. Keeps the vocabulary clean.
    func mergeTag(_ sourceID: String, into targetID: String) {
        guard sourceID != targetID, let src = tag(sourceID) else { return }
        mutate { doc in
            for i in doc.notes.indices where doc.notes[i].tagIDs.contains(sourceID) {
                doc.notes[i].tagIDs.removeAll { $0 == sourceID }
                if !doc.notes[i].tagIDs.contains(targetID) { doc.notes[i].tagIDs.append(targetID) }
            }
            if let ti = doc.tags.firstIndex(where: { $0.id == targetID }) {
                if !doc.tags[ti].aliases.contains(where: { $0.lowercased() == src.name.lowercased() }) {
                    doc.tags[ti].aliases.append(src.name)
                }
            }
            doc.tags.removeAll { $0.id == sourceID }
        }
    }

    // MARK: Notes & linking

    /// The catalog row for a note file (relative path), created on demand.
    @discardableResult
    func note(forRelativePath path: String, title: String, date: Date?) -> CatalogNote {
        if let existing = doc.notes.first(where: { $0.filePath == path }) { return existing }
        let n = CatalogNote(filePath: path, title: title, date: date)
        mutate { $0.notes.append(n) }
        return n
    }
    func update(_ n: CatalogNote) {
        mutate { doc in if let i = doc.notes.firstIndex(where: { $0.filePath == n.filePath }) { doc.notes[i] = n } }
    }
    func note(id: String) -> CatalogNote? { doc.notes.first { $0.id == id } }

    func setTag(_ tagID: String, on noteID: String, _ on: Bool) {
        mutate { doc in
            guard let i = doc.notes.firstIndex(where: { $0.id == noteID }) else { return }
            if on { if !doc.notes[i].tagIDs.contains(tagID) { doc.notes[i].tagIDs.append(tagID) } }
            else { doc.notes[i].tagIDs.removeAll { $0 == tagID } }
        }
    }
    /// Directly assign a note to an org (for internal notes with no opportunity).
    /// A note is assigned to *either* an opportunity *or* an org — assigning an
    /// org clears any opportunity links, and vice-versa.
    func setOrg(_ orgID: String, on noteID: String, _ on: Bool) {
        mutate { doc in
            guard let i = doc.notes.firstIndex(where: { $0.id == noteID }) else { return }
            if on {
                doc.notes[i].opportunityIDs.removeAll()          // mutually exclusive
                if !doc.notes[i].orgIDs.contains(orgID) { doc.notes[i].orgIDs.append(orgID) }
            } else {
                doc.notes[i].orgIDs.removeAll { $0 == orgID }
            }
        }
    }
    func setProject(_ projectID: String, on noteID: String, _ on: Bool) {
        mutate { doc in
            guard let i = doc.notes.firstIndex(where: { $0.id == noteID }) else { return }
            if on { if !doc.notes[i].projectIDs.contains(projectID) { doc.notes[i].projectIDs.append(projectID) } }
            else { doc.notes[i].projectIDs.removeAll { $0 == projectID } }
        }
    }
    func setOpportunity(_ oppID: String, on noteID: String, _ on: Bool) {
        mutate { doc in
            guard let i = doc.notes.firstIndex(where: { $0.id == noteID }) else { return }
            if on {
                doc.notes[i].orgIDs.removeAll()                  // mutually exclusive with a direct org
                if !doc.notes[i].opportunityIDs.contains(oppID) { doc.notes[i].opportunityIDs.append(oppID) }
            } else {
                doc.notes[i].opportunityIDs.removeAll { $0 == oppID }
            }
        }
    }

    // MARK: Indexing existing notes

    /// Scan the notes folder for **meeting notes only** (`Meeting_*.md`) and
    /// ensure each has a catalog row. Dictations, quick notes and any other
    /// files are ignored. Existing rows and their links are left untouched;
    /// non-destructive and safe to re-run.
    @discardableResult
    func indexNotesFolder() -> Int {
        let fm = FileManager.default
        let root = AppSettings.shared.notesFolder
        let dictations = AppSettings.shared.dictationsFolder.path
        guard let items = fm.enumerator(at: root, includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey]) else { return 0 }
        var newRows: [CatalogNote] = []
        let known = Set(doc.notes.map { $0.filePath })
        for case let url as URL in items {
            guard url.pathExtension.lowercased() == "md",
                  url.lastPathComponent.hasPrefix("Meeting_"),   // notes only
                  !url.path.hasPrefix(dictations) else { continue }
            let rel = url.path.replacingOccurrences(of: root.path + "/", with: "")
            guard !known.contains(rel) else { continue }
            let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            let date = values?.creationDate ?? values?.contentModificationDate
            newRows.append(CatalogNote(filePath: rel,
                                       title: url.deletingPathExtension().lastPathComponent,
                                       date: date))
        }
        if !newRows.isEmpty { mutate { $0.notes.append(contentsOf: newRows) } }
        return newRows.count
    }

    /// Full text of a note file (cached lightly by path+mtime would be nicer;
    /// at personal scale a direct read is fine).
    private func body(of note: CatalogNote) -> String {
        let url = AppSettings.shared.notesFolder.appendingPathComponent(note.filePath)
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// Title/body substring match for the in-catalog text search.
    func noteMatches(_ note: CatalogNote, query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        if note.title.lowercased().contains(q) { return true }
        return body(of: note).lowercased().contains(q)
    }

    /// Absolute URL for a note file.
    func url(of note: CatalogNote) -> URL {
        AppSettings.shared.notesFolder.appendingPathComponent(note.filePath)
    }

    /// Tags a note's own front-matter suggests but that aren't applied yet.
    /// Reads the `tags: [...]` YAML line (skipping the boilerplate meeting/
    /// ghostwriter markers). Purely a suggestion source — never auto-applied.
    func suggestedTags(for note: CatalogNote) -> [String] {
        let url = AppSettings.shared.notesFolder.appendingPathComponent(note.filePath)
        guard let content = try? String(contentsOf: url, encoding: .utf8), content.hasPrefix("---") else { return [] }
        let lines = content.components(separatedBy: .newlines)
        guard let end = lines.dropFirst().firstIndex(where: { $0 == "---" }),
              let tagLine = lines[1..<end].first(where: { $0.hasPrefix("tags:") }) else { return [] }
        let inside = tagLine.drop(while: { $0 != "[" }).dropFirst().prefix(while: { $0 != "]" })
        let boilerplate: Set<String> = ["meeting", "ghostwriter", "dictation"]
        let applied = Set((note.tagIDs.compactMap { tag($0)?.name.lowercased() }))
        var seen = Set<String>(), out: [String] = []
        for raw in inside.split(separator: ",") {
            let t = raw.trimmingCharacters(in: .whitespaces)
            let key = t.lowercased()
            guard !t.isEmpty, !boilerplate.contains(key), !applied.contains(key),
                  seen.insert(key).inserted else { continue }
            out.append(t)
        }
        return out
    }
}
