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
    /// The person's type — a link into the user-managed `personTypes` vocabulary
    /// (Internal, External › Partner, …). `nil` means "no type set".
    var typeID: String?
    /// Legacy free-text side ("internal" | "external"). Kept only so older
    /// catalogs still decode; migrated into `typeID` on load, never surfaced.
    var channel: String?
    var email: String?
    var phone: String?
    /// Job title / role (e.g. "VP Engineering"). Optional so older catalogs decode.
    var designation: String?
}

/// A user-defined person classification (e.g. Internal, External, Partner).
/// Forms an unlimited hierarchy via `parentID`, mirroring orgs/projects, so
/// people can be grouped as, say, External › Partner. Cycles are prevented on
/// assignment.
struct CatalogPersonType: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var name: String
    var parentID: String?
}

enum OppStage: String, Codable, CaseIterable, Identifiable {
    case open, won, lost
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

/// A project — the unit a note is filed under (besides a direct org link).
/// Projects form an unlimited hierarchy via `parentID` (like orgs); a
/// top-level project carries an `orgID`, sub-projects inherit their org from an
/// ancestor. Proof-of-concept success criteria hang off the project.
struct CatalogProject: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var name: String
    var orgID: String?
    /// Parent project — nil for a top-level project. Enables sub-projects.
    var parentID: String?
    var stage: OppStage = .open
    var valueCents: Int?
    var currency = "USD"
    var archived = false
    /// Proof-of-concept records tracked under this project. A project can hold
    /// several POCs, each with its own criteria, timeline, and lifecycle phase.
    var pocs: [Poc] = []

    enum CodingKeys: String, CodingKey {
        case id, name, orgID, parentID, stage, valueCents, currency, archived, pocs
        // Legacy (pre-multi-POC) keys — decoded into a migrated POC, never written.
        case pocCriteria, pocDeadline
    }

    init(id: String = UUID().uuidString, name: String, orgID: String? = nil,
         parentID: String? = nil, stage: OppStage = .open, valueCents: Int? = nil,
         currency: String = "USD", archived: Bool = false, pocs: [Poc] = []) {
        self.id = id; self.name = name; self.orgID = orgID; self.parentID = parentID
        self.stage = stage; self.valueCents = valueCents; self.currency = currency
        self.archived = archived; self.pocs = pocs
    }

    /// Tolerant decoder: fields added after v1 (`parentID`, `stage`,
    /// `valueCents`, `currency`, `pocs`) are optional on the wire, so catalogs
    /// exported before they existed still load. A legacy single-POC project
    /// (criteria/deadline hung directly off the project) is migrated into one
    /// `Poc`. Any legacy `opportunities` array in the JSON is simply ignored.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decode(String.self, forKey: .name)
        orgID = try c.decodeIfPresent(String.self, forKey: .orgID)
        parentID = try c.decodeIfPresent(String.self, forKey: .parentID)
        stage = try c.decodeIfPresent(OppStage.self, forKey: .stage) ?? .open
        valueCents = try c.decodeIfPresent(Int.self, forKey: .valueCents)
        currency = try c.decodeIfPresent(String.self, forKey: .currency) ?? "USD"
        archived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        pocs = try c.decodeIfPresent([Poc].self, forKey: .pocs) ?? []
        // Migrate a legacy single POC into the new list.
        let legacyCriteria = try c.decodeIfPresent([PocCriterion].self, forKey: .pocCriteria) ?? []
        let legacyDeadline = try c.decodeIfPresent(Date.self, forKey: .pocDeadline)
        if pocs.isEmpty && (!legacyCriteria.isEmpty || legacyDeadline != nil) {
            pocs = [Poc(name: "POC", criteria: legacyCriteria, deadline: legacyDeadline)]
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(orgID, forKey: .orgID)
        try c.encodeIfPresent(parentID, forKey: .parentID)
        try c.encode(stage, forKey: .stage)
        try c.encodeIfPresent(valueCents, forKey: .valueCents)
        try c.encode(currency, forKey: .currency)
        try c.encode(archived, forKey: .archived)
        try c.encode(pocs, forKey: .pocs)
    }
}

/// A proof-of-concept tracked under a project. A project can hold several; each
/// owns its criteria, an optional start→deadline window, and a lifecycle phase.
struct Poc: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var name: String
    /// What this POC must prove — free text shown atop the detail pane.
    var detail: String = ""
    var phase: PocPhase = .planned
    var criteria: [PocCriterion] = []
    var startDate: Date?
    var deadline: Date?

    /// Leaf criteria — the ones that carry a real pass/fail. Parents are just
    /// groupings, so the tallies count leaves to avoid double-counting. A flat
    /// (un-nested) POC has every criterion as a leaf.
    var leaves: [PocCriterion] {
        let parents = Set(criteria.compactMap { $0.parentID })
        return criteria.filter { !parents.contains($0.id) }
    }
    var passed: Int  { leaves.filter { $0.status == .pass }.count }
    var failed: Int  { leaves.filter { $0.status == .fail }.count }
    var blocked: Int { leaves.filter { $0.status == .blocked }.count }
    var total: Int   { leaves.count }

    /// At risk when a leaf has failed or is blocked, or nothing has passed yet.
    /// Only meaningful once criteria exist.
    var isAtRisk: Bool {
        let ls = leaves
        return ls.contains { $0.status == .fail || $0.status == .blocked } || !ls.contains { $0.status == .pass }
    }

    enum CodingKeys: String, CodingKey { case id, name, detail, phase, criteria, startDate, deadline }
    init(id: String = UUID().uuidString, name: String, detail: String = "",
         phase: PocPhase = .planned, criteria: [PocCriterion] = [],
         startDate: Date? = nil, deadline: Date? = nil) {
        self.id = id; self.name = name; self.detail = detail; self.phase = phase
        self.criteria = criteria; self.startDate = startDate; self.deadline = deadline
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "POC"
        detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
        phase = try c.decodeIfPresent(PocPhase.self, forKey: .phase) ?? .planned
        criteria = try c.decodeIfPresent([PocCriterion].self, forKey: .criteria) ?? []
        startDate = try c.decodeIfPresent(Date.self, forKey: .startDate)
        deadline = try c.decodeIfPresent(Date.self, forKey: .deadline)
    }
}

/// A POC's lifecycle phase — set by the user, distinct from the criteria-derived
/// health. Drives grouping and the phase pill in the tracker.
enum PocPhase: String, Codable, CaseIterable, Identifiable {
    case planned, active, passed, failed, onHold
    var id: String { rawValue }
    var label: String {
        switch self {
        case .planned: return "Planned"
        case .active:  return "In progress"
        case .passed:  return "Passed"
        case .failed:  return "Failed"
        case .onHold:  return "On hold"
        }
    }
    /// Ordering weight — active work first, closed/paused work last.
    var order: Int {
        switch self { case .active: 0; case .planned: 1; case .failed: 2; case .onHold: 3; case .passed: 4 }
    }
    /// "Open" = still in flight (planned / in progress / on hold). Passed and
    /// failed are closed outcomes. Drives the tracker's default Open-only filter.
    var isOpen: Bool {
        switch self { case .planned, .active, .onHold: true; case .passed, .failed: false }
    }
}

/// Where a POC success criterion stands. `pending` until an evaluation lands.
enum PocStatus: String, Codable, CaseIterable {
    case pending, pass, fail, blocked
    var label: String {
        switch self {
        case .pending: return "Pending"
        case .pass:    return "Passed"
        case .fail:    return "Failed"
        case .blocked: return "Blocked"
        }
    }
    /// Cycle pending → pass → fail → blocked → pending for a one-tap control.
    var next: PocStatus {
        switch self {
        case .pending: return .pass
        case .pass:    return .fail
        case .fail:    return .blocked
        case .blocked: return .pending
        }
    }
}

/// A single POC success criterion. Criteria form an unlimited hierarchy via
/// `parentID` (nil = top-level); a parent groups its children, and only leaf
/// criteria carry the measurable pass/fail that rolls up the tallies.
struct PocCriterion: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var text: String
    /// Optional longer description / acceptance detail. Hidden by default in
    /// the tracker, expanded on demand. Defaults to "" so older Catalog.json
    /// (which lacks the key) decodes cleanly.
    var detail: String = ""
    var status: PocStatus = .pending
    /// Parent criterion — nil for a top-level item. Enables sub-criteria.
    var parentID: String?
    /// Who owns this criterion (free text — a name, or "Vendor" / "Customer")
    /// and its target date. Both optional so older Catalog.json decodes cleanly.
    var owner: String?
    var dueDate: Date?
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
    /// A note is filed under a project *or* a direct org (mutually exclusive).
    /// The rest of the chain — project → parent projects → org → people — is
    /// inherited automatically. `orgIDs` holds a direct org assignment for
    /// internal notes with no project.
    var projectIDs: [String] = []
    var orgIDs: [String] = []
    var tagIDs: [String] = []
    /// People attributed directly to this note (attendees / mentioned), set per
    /// note like tags. Independent of org membership.
    var personIDs: [String] = []
}

// MARK: Named — one shared case-insensitive sort for every named entity

protocol Named { var name: String { get } }
extension CatalogOrg: Named {}
extension CatalogPerson: Named {}
extension CatalogPersonType: Named {}
extension CatalogProject: Named {}
extension CatalogTag: Named {}

extension Sequence where Element: Named {
    /// Case-insensitive, locale-aware ascending sort by `name`.
    var sortedByName: [Element] {
        sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

extension Sequence where Element == CatalogNote {
    /// Newest first — undated notes sort last.
    var sortedByDateDescending: [CatalogNote] {
        sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }
}

// MARK: Document

/// The whole catalog, serialised as one JSON file.
struct CatalogDocument: Codable {
    var schemaVersion = 1
    var orgs: [CatalogOrg] = []
    var people: [CatalogPerson] = []
    /// User-managed person classifications (hierarchical). Optional on the wire
    /// so catalogs written before the feature still decode.
    var personTypes: [CatalogPersonType] = []
    var projects: [CatalogProject] = []
    var tags: [CatalogTag] = []
    var notes: [CatalogNote] = []

    init() {}

    enum CodingKeys: String, CodingKey {
        case schemaVersion, orgs, people, personTypes, projects, tags, notes
    }

    /// Tolerant decoder: every collection is optional on the wire, so a catalog
    /// written before a field existed (notably `personTypes`) still loads
    /// instead of throwing and appearing to wipe the catalog.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        orgs = try c.decodeIfPresent([CatalogOrg].self, forKey: .orgs) ?? []
        people = try c.decodeIfPresent([CatalogPerson].self, forKey: .people) ?? []
        personTypes = try c.decodeIfPresent([CatalogPersonType].self, forKey: .personTypes) ?? []
        projects = try c.decodeIfPresent([CatalogProject].self, forKey: .projects) ?? []
        tags = try c.decodeIfPresent([CatalogTag].self, forKey: .tags) ?? []
        notes = try c.decodeIfPresent([CatalogNote].self, forKey: .notes) ?? []
    }
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

    /// Shared JSON coders. The encoder/decoder settings must stay in lockstep
    /// (dates especially) or a round-trip throws and the data "vanishes".
    private static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
    private static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? Self.makeDecoder().decode(CatalogDocument.self, from: data) else { return }
        doc = decoded
        migratePersonTypes()
        backfillDates()   // heal rows saved without a date so they aren't hidden
    }

    /// One-time upgrade of the legacy free-text `channel` into the managed
    /// `personTypes` vocabulary. Seeds a default hierarchy the first time any
    /// legacy channel is seen (or the doc has people but no types), then maps
    /// each person's channel onto the matching type and clears the old field.
    /// Idempotent: a doc that already has types and no channels is left alone.
    private func migratePersonTypes() {
        // Nothing to migrate unless some person still carries a legacy channel.
        guard doc.people.contains(where: { !($0.channel ?? "").isEmpty }) else { return }

        // Seed defaults only when the vocabulary is empty, so we never clobber a
        // user's own types. External is a parent of the sales-facing kinds.
        if doc.personTypes.isEmpty {
            let internalT = CatalogPersonType(name: "Internal")
            let external  = CatalogPersonType(name: "External")
            let partner   = CatalogPersonType(name: "Partner",  parentID: external.id)
            let customer  = CatalogPersonType(name: "Customer", parentID: external.id)
            let prospect  = CatalogPersonType(name: "Prospect", parentID: external.id)
            doc.personTypes = [internalT, external, partner, customer, prospect]
        }

        // Map each legacy channel string onto a type by name (case-insensitive).
        func typeID(named name: String) -> String? {
            doc.personTypes.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.id
        }
        for i in doc.people.indices {
            defer { doc.people[i].channel = nil }
            guard let ch = doc.people[i].channel, !ch.isEmpty, doc.people[i].typeID == nil else { continue }
            doc.people[i].typeID = typeID(named: ch)
        }
        save()
    }

    private func save() {
        let dir = AppSettings.shared.notesFolder
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? Self.makeEncoder().encode(doc) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: Export / Import

    enum ImportMode { case merge, replace }

    /// True when there's nothing to export — disables the Export button.
    var isEmpty: Bool {
        doc.orgs.isEmpty && doc.people.isEmpty && doc.projects.isEmpty
            && doc.tags.isEmpty && doc.notes.isEmpty
    }

    /// Encode the whole catalog for export — identical format to the on-disk
    /// `Catalog.json`, so an exported file is a drop-in backup.
    func exportData() throws -> Data { try Self.makeEncoder().encode(doc) }

    /// True if `data` decodes as a catalog — used to reject junk files before
    /// offering merge/replace.
    func isValidCatalog(_ data: Data) -> Bool {
        (try? Self.makeDecoder().decode(CatalogDocument.self, from: data)) != nil
    }

    /// Fold an exported catalog into this one. `merge` upserts every record by
    /// id (incoming wins on a clash, existing records are otherwise kept);
    /// `replace` swaps the entire catalog. Returns the record count in the
    /// imported file. Throws on malformed JSON. Note files are never touched.
    @discardableResult
    func importData(_ data: Data, mode: ImportMode) throws -> Int {
        let incoming = try Self.makeDecoder().decode(CatalogDocument.self, from: data)
        mutate { doc in
            switch mode {
            case .replace:
                doc = incoming
            case .merge:
                Self.upsert(&doc.orgs, incoming.orgs)
                Self.upsert(&doc.people, incoming.people)
                Self.upsert(&doc.personTypes, incoming.personTypes)
                Self.upsert(&doc.projects, incoming.projects)
                Self.upsert(&doc.tags, incoming.tags)
                Self.upsert(&doc.notes, incoming.notes)
            }
        }
        return incoming.orgs.count + incoming.people.count + incoming.projects.count
             + incoming.tags.count + incoming.notes.count
    }

    /// Merge `incoming` into `base` by id: existing entries with a matching id
    /// are overwritten, genuinely new ones appended, order otherwise preserved.
    private static func upsert<T: Identifiable>(_ base: inout [T], _ incoming: [T]) where T.ID == String {
        var indexByID = Dictionary(base.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        for item in incoming {
            if let i = indexByID[item.id] {
                base[i] = item
            } else {
                indexByID[item.id] = base.count
                base.append(item)
            }
        }
    }

    // MARK: POC records & success criteria

    /// Every POC in the catalog paired with its owning project — the unit the
    /// tracker lists, filters, and groups. Newest-touched projects aside, order
    /// is stable (project order, then the project's POC order).
    var allPocs: [(project: CatalogProject, poc: Poc)] {
        doc.projects.filter { !$0.archived }.flatMap { p in p.pocs.map { (p, $0) } }
    }

    /// Locate a POC and its project by POC id.
    func poc(_ pocID: String) -> (project: CatalogProject, poc: Poc)? {
        for p in doc.projects { if let m = p.pocs.first(where: { $0.id == pocID }) { return (p, m) } }
        return nil
    }

    /// Create a new POC under a project and return its id.
    @discardableResult
    func addPoc(name: String, to projID: String) -> String? {
        let clean = name.trimmingCharacters(in: .whitespaces)
        var newID: String?
        mutate { doc in
            guard let i = doc.projects.firstIndex(where: { $0.id == projID }) else { return }
            let poc = Poc(name: clean.isEmpty ? "POC \(doc.projects[i].pocs.count + 1)" : clean)
            newID = poc.id
            doc.projects[i].pocs.append(poc)
        }
        return newID
    }

    /// Remove a whole POC from its project.
    func removePoc(_ pocID: String, from projID: String) {
        mutatePoc(pocID, in: projID) { _ in } removingIf: { _ in true }
    }

    /// In-place edit of a single POC. `change` mutates it; if `removingIf`
    /// returns true afterward the POC is dropped instead.
    private func mutatePoc(_ pocID: String, in projID: String,
                           _ change: (inout Poc) -> Void,
                           removingIf remove: (Poc) -> Bool = { _ in false }) {
        mutate { doc in
            guard let pi = doc.projects.firstIndex(where: { $0.id == projID }),
                  let mi = doc.projects[pi].pocs.firstIndex(where: { $0.id == pocID }) else { return }
            if remove(doc.projects[pi].pocs[mi]) { doc.projects[pi].pocs.remove(at: mi); return }
            change(&doc.projects[pi].pocs[mi])
        }
    }

    func renamePoc(_ pocID: String, in projID: String, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return }
        mutatePoc(pocID, in: projID) { $0.name = clean }
    }
    func setPocDetail(_ text: String, pocID: String, in projID: String) {
        mutatePoc(pocID, in: projID) { $0.detail = text }
    }
    func setPocPhase(_ phase: PocPhase, pocID: String, in projID: String) {
        mutatePoc(pocID, in: projID) { $0.phase = phase }
    }
    func setPocStartDate(_ date: Date?, pocID: String, in projID: String) {
        mutatePoc(pocID, in: projID) { $0.startDate = date }
    }
    func setPocDeadline(_ date: Date?, pocID: String, in projID: String) {
        mutatePoc(pocID, in: projID) { $0.deadline = date }
    }

    /// Bulk-add criteria to a POC (e.g. AI-extracted), skipping any whose text
    /// already exists on that POC (case-insensitive). Returns how many landed.
    @discardableResult
    func addPocCriteriaTexts(_ texts: [String], toPoc pocID: String, in projID: String) -> Int {
        var added = 0
        mutatePoc(pocID, in: projID) { poc in
            var existing = Set(poc.criteria.map { $0.text.lowercased() })
            for raw in texts {
                let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                let key = t.lowercased()
                guard !t.isEmpty, !existing.contains(key) else { continue }
                poc.criteria.append(PocCriterion(text: t))
                existing.insert(key)
                added += 1
            }
        }
        return added
    }

    /// Bulk-insert a depth-tagged list of criteria as a hierarchy (from a pasted,
    /// indented list). `depth` is the 0-based indent level; each line nests under
    /// the most recent shallower line, rooted at `under`. Returns how many landed.
    @discardableResult
    func addPocCriteriaTree(_ lines: [(text: String, depth: Int)], under root: String?,
                            toPoc pocID: String, in projID: String) -> Int {
        var added = 0
        mutatePoc(pocID, in: projID) { poc in
            // Stack of (depth, id); the synthetic base maps any top-level line to `root`.
            var stack: [(depth: Int, id: String?)] = [(-1, root)]
            for line in lines {
                let t = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty else { continue }
                while let top = stack.last, top.depth >= line.depth { stack.removeLast() }
                let parent = stack.last?.id ?? root
                let c = PocCriterion(text: t, status: .pending, parentID: parent)
                poc.criteria.append(c)
                stack.append((line.depth, c.id))
                added += 1
            }
        }
        return added
    }

    /// Edit a criterion's text (ignores an empty/whitespace-only value).
    func setPocCriterionText(_ text: String, criterionID: String, pocID: String, projID: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        mutatePoc(pocID, in: projID) { poc in
            if let ci = poc.criteria.firstIndex(where: { $0.id == criterionID }) { poc.criteria[ci].text = t }
        }
    }

    /// Edit a criterion's optional description (trimmed; may be cleared to "").
    func setPocCriterionDetail(_ detail: String, criterionID: String, pocID: String, projID: String) {
        let d = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        mutatePoc(pocID, in: projID) { poc in
            if let ci = poc.criteria.firstIndex(where: { $0.id == criterionID }) { poc.criteria[ci].detail = d }
        }
    }

    func setPocStatus(_ status: PocStatus, criterionID: String, pocID: String, projID: String) {
        mutatePoc(pocID, in: projID) { poc in
            if let ci = poc.criteria.firstIndex(where: { $0.id == criterionID }) { poc.criteria[ci].status = status }
        }
    }

    /// Set a criterion's owner (trimmed; empty clears it to nil).
    func setPocCriterionOwner(_ owner: String, criterionID: String, pocID: String, projID: String) {
        let o = owner.trimmingCharacters(in: .whitespaces)
        mutatePoc(pocID, in: projID) { poc in
            if let ci = poc.criteria.firstIndex(where: { $0.id == criterionID }) {
                poc.criteria[ci].owner = o.isEmpty ? nil : o
            }
        }
    }

    /// Set (or clear) a criterion's target date.
    func setPocCriterionDueDate(_ date: Date?, criterionID: String, pocID: String, projID: String) {
        mutatePoc(pocID, in: projID) { poc in
            if let ci = poc.criteria.firstIndex(where: { $0.id == criterionID }) { poc.criteria[ci].dueDate = date }
        }
    }

    /// Reorder a criterion among its siblings (same `parentID`) by swapping with
    /// the adjacent one. Descendants stay linked via `parentID`, so the whole
    /// sub-tree moves with it. No-op at the ends.
    func movePocCriterion(_ criterionID: String, up: Bool, pocID: String, projID: String) {
        mutatePoc(pocID, in: projID) { poc in
            guard let c = poc.criteria.first(where: { $0.id == criterionID }) else { return }
            let sibs = poc.criteria.enumerated().filter { $0.element.parentID == c.parentID }
            guard let pos = sibs.firstIndex(where: { $0.element.id == criterionID }) else { return }
            let other = up ? pos - 1 : pos + 1
            guard other >= 0, other < sibs.count else { return }
            poc.criteria.swapAt(sibs[pos].offset, sibs[other].offset)
        }
    }

    /// Remove a criterion and its whole sub-tree (descendants by `parentID`).
    func removePocCriterion(_ criterionID: String, pocID: String, from projID: String) {
        mutatePoc(pocID, in: projID) { poc in
            var doomed: Set<String> = [criterionID]
            var grew = true
            while grew {
                grew = false
                for c in poc.criteria where !doomed.contains(c.id) && (c.parentID.map(doomed.contains) ?? false) {
                    doomed.insert(c.id); grew = true
                }
            }
            poc.criteria.removeAll { doomed.contains($0.id) }
        }
    }

    /// Drop every success criterion from a single POC (the POC record stays).
    func clearPocCriteria(pocID: String, in projID: String) {
        mutatePoc(pocID, in: projID) { $0.criteria.removeAll() }
    }

    /// Route every mutation through here so persistence is never forgotten.
    private func mutate(_ change: (inout CatalogDocument) -> Void) {
        objectWillChange.send()
        change(&doc)
        save()
    }

    /// Handle the notes folder being pointed somewhere new in Settings.
    /// `Catalog.json` lives *in* the notes folder, and every note is stored as
    /// a path relative to it — so if we did nothing, the next `load()` would
    /// read an absent file at the new location and the catalog would look
    /// wiped (with the old one orphaned behind it). Instead we carry the file
    /// across: if the old folder had a catalog and the new one doesn't, move
    /// it, then reload so memory matches disk. A folder that already has its
    /// own `Catalog.json` is respected (loaded, not overwritten). Note files
    /// themselves are never moved — that's the user's choice.
    func notesFolderDidChange(from oldFolder: URL) {
        let fm = FileManager.default
        let newFolder = AppSettings.shared.notesFolder
        guard oldFolder.standardizedFileURL.path != newFolder.standardizedFileURL.path else { return }
        let oldFile = oldFolder.appendingPathComponent("Catalog.json")
        let newFile = newFolder.appendingPathComponent("Catalog.json")
        if fm.fileExists(atPath: oldFile.path), !fm.fileExists(atPath: newFile.path) {
            try? fm.createDirectory(at: newFolder, withIntermediateDirectories: true)
            try? fm.moveItem(at: oldFile, to: newFile)
        }
        load()   // if the move (or an existing catalog) gave us a file to read; otherwise a no-op that keeps memory intact
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
    private static func lineage(of id: String, exists: (String) -> Bool, parentOf: (String) -> String?) -> [String] {
        var chain: [String] = [], cur: String? = id, seen = Set<String>()
        while let c = cur, seen.insert(c).inserted, exists(c) {
            chain.append(c); cur = parentOf(c)
        }
        return chain
    }
    private static func subtree(of id: String, children: (String) -> [String]) -> Set<String> {
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
            // Every project rooted at this org, plus their sub-project subtrees.
            var projIDs = Set(doc.projects.filter { $0.orgID == id }.map { $0.id })
            var frontier = projIDs
            while !frontier.isEmpty {
                let children = Set(doc.projects.filter { $0.parentID.map { frontier.contains($0) } ?? false }.map { $0.id })
                frontier = children.subtracting(projIDs)
                projIDs.formUnion(children)
            }
            doc.orgs.removeAll { $0.id == id }
            for i in doc.orgs.indices where doc.orgs[i].parentID == id { doc.orgs[i].parentID = nil } // reparent to root
            doc.projects.removeAll { projIDs.contains($0.id) }          // cascade projects
            for i in doc.notes.indices {
                doc.notes[i].orgIDs.removeAll { $0 == id }
                doc.notes[i].projectIDs.removeAll { projIDs.contains($0) }
            }
        }
    }

    // MARK: Person / Project / Tag CRUD

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
        mutate { doc in
            doc.people.removeAll { $0.id == id }
            for i in doc.notes.indices { doc.notes[i].personIDs.removeAll { $0 == id } }
        }
    }

    // MARK: Bulk person operations

    /// Create many people at once from fully-formed records (name + optional
    /// email / phone / designation / type). De-duplicates by name against the
    /// existing catalog and within the batch, so re-running is safe. Returns the
    /// people actually created.
    @discardableResult
    func addPeople(_ incoming: [CatalogPerson]) -> [CatalogPerson] {
        let existing = Set(doc.people.map { $0.name.lowercased() })
        var seen = Set<String>(), created: [CatalogPerson] = []
        for var p in incoming {
            let n = p.name.trimmingCharacters(in: .whitespaces)
            let key = n.lowercased()
            guard !n.isEmpty, !existing.contains(key), seen.insert(key).inserted else { continue }
            p.name = n
            created.append(p)
        }
        guard !created.isEmpty else { return [] }
        mutate { $0.people.append(contentsOf: created) }
        return created
    }

    /// Delete several people and scrub them from every note in one pass.
    func deletePeople(_ ids: [String]) {
        let gone = Set(ids)
        guard !gone.isEmpty else { return }
        mutate { doc in
            doc.people.removeAll { gone.contains($0.id) }
            for i in doc.notes.indices { doc.notes[i].personIDs.removeAll { gone.contains($0) } }
        }
    }

    /// Reassign the type of several people at once (nil = clear the type).
    func setPersonType(_ ids: [String], to typeID: String?) {
        let target = Set(ids)
        guard !target.isEmpty else { return }
        mutate { doc in
            for i in doc.people.indices where target.contains(doc.people[i].id) {
                doc.people[i].typeID = typeID
            }
        }
    }

    // MARK: Person types (hierarchical)

    func personType(_ id: String?) -> CatalogPersonType? { doc.personTypes.first { $0.id == id } }
    var personTypesSorted: [CatalogPersonType] { doc.personTypes.sortedByName }
    var rootPersonTypes: [CatalogPersonType] {
        personTypesSorted.filter { $0.parentID == nil || personType($0.parentID) == nil }
    }
    func childPersonTypes(of id: String) -> [CatalogPersonType] {
        personTypesSorted.filter { $0.parentID == id }
    }
    /// `id` plus all descendant types — for cycle-safe parent choices and delete.
    func personTypeSubtree(of id: String) -> Set<String> {
        Self.subtree(of: id, children: { childPersonTypes(of: $0).map(\.id) })
    }
    /// "External › Partner" lineage for display.
    func personTypePath(of id: String) -> String {
        Self.lineage(of: id, exists: { personType($0) != nil }, parentOf: { personType($0)?.parentID })
            .reversed().compactMap { personType($0)?.name }.joined(separator: " › ")
    }

    @discardableResult
    func addPersonType(name: String, parentID: String? = nil) -> CatalogPersonType {
        let n = name.trimmingCharacters(in: .whitespaces)
        if let existing = doc.personTypes.first(where: {
            $0.name.caseInsensitiveCompare(n) == .orderedSame && $0.parentID == parentID
        }) { return existing }
        let t = CatalogPersonType(name: n.isEmpty ? "New Type" : n, parentID: parentID)
        mutate { $0.personTypes.append(t) }
        return t
    }
    func update(_ t: CatalogPersonType) {
        var type = t
        // Reject a parent that would create a cycle (self or a descendant).
        if let parent = type.parentID, personTypeSubtree(of: type.id).contains(parent) { type.parentID = nil }
        mutate { doc in if let i = doc.personTypes.firstIndex(where: { $0.id == type.id }) { doc.personTypes[i] = type } }
    }
    /// Delete a type and its whole subtree; people that pointed at any removed
    /// type fall back to "no type".
    func deletePersonType(_ id: String) {
        let gone = personTypeSubtree(of: id)
        mutate { doc in
            doc.personTypes.removeAll { gone.contains($0.id) }
            for i in doc.people.indices where doc.people[i].typeID.map(gone.contains) == true {
                doc.people[i].typeID = nil
            }
        }
    }
    /// People carrying a given type (nil = untyped). Sorted by name.
    func people(ofType typeID: String?) -> [CatalogPerson] {
        doc.people.sortedByName.filter { $0.typeID == typeID }
    }

    @discardableResult
    func addProject(name: String, orgID: String? = nil, parentID: String? = nil) -> CatalogProject {
        var p = CatalogProject(name: name, orgID: orgID)
        p.parentID = parentID
        mutate { $0.projects.append(p) }
        return p
    }
    func update(_ p: CatalogProject) {
        var proj = p
        // Reject a parent that would create a cycle (self or a descendant).
        if let parent = proj.parentID, projectSubtree(of: proj.id).contains(parent) { proj.parentID = nil }
        mutate { doc in if let i = doc.projects.firstIndex(where: { $0.id == proj.id }) { doc.projects[i] = proj } }
    }
    func deleteProject(_ id: String) {
        let gone = projectSubtree(of: id)   // the project and all its sub-projects
        mutate { doc in
            doc.projects.removeAll { gone.contains($0.id) }
            for i in doc.notes.indices { doc.notes[i].projectIDs.removeAll { gone.contains($0) } }
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

    // MARK: Bulk tag operations

    /// Create many tags at once (one name per line). Folds onto existing tags by
    /// name/alias, so re-running is safe. Returns the tags that were created.
    @discardableResult
    func addTags(names: [String]) -> [CatalogTag] {
        var created: [CatalogTag] = []
        for raw in names {
            let n = raw.trimmingCharacters(in: .whitespaces)
            guard !n.isEmpty else { continue }
            let before = doc.tags.count
            let t = addTag(name: n)          // dedupes by name/alias
            if doc.tags.count > before { created.append(t) }
        }
        return created
    }

    /// Delete several tags and scrub them from every note in one pass.
    func deleteTags(_ ids: [String]) {
        let gone = Set(ids)
        guard !gone.isEmpty else { return }
        mutate { doc in
            doc.tags.removeAll { gone.contains($0.id) }
            for i in doc.notes.indices { doc.notes[i].tagIDs.removeAll { gone.contains($0) } }
        }
    }

    // MARK: Notes & linking

    /// The catalog row for a note file (relative path), created on demand.
    @discardableResult
    func note(forRelativePath path: String, title: String, date: Date?) -> CatalogNote {
        if let existing = doc.notes.first(where: { $0.filePath == path }) { return existing }
        // Always give a note a date — a nil date makes it vanish under any active
        // time-window filter (e.g. the default "30 days"). Fall back to the file's
        // own creation/modification time when the caller didn't supply one.
        let n = CatalogNote(filePath: path, title: title, date: date ?? Self.fileDate(forRelativePath: path))
        mutate { $0.notes.append(n) }
        return n
    }

    /// The on-disk creation (else modification) date of a note file, used as a
    /// fallback so every catalog row carries a date.
    private static func fileDate(forRelativePath path: String) -> Date? {
        let url = AppSettings.shared.notesFolder.appendingPathComponent(path)
        let v = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return v?.creationDate ?? v?.contentModificationDate
    }
    func update(_ n: CatalogNote) {
        mutate { doc in if let i = doc.notes.firstIndex(where: { $0.filePath == n.filePath }) { doc.notes[i] = n } }
    }
    /// Update a row's display title (e.g. once an AI title is generated).
    func renameNote(relativePath: String, to title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        mutate { doc in if let i = doc.notes.firstIndex(where: { $0.filePath == relativePath }) { doc.notes[i].title = t } }
    }
    func note(id: String) -> CatalogNote? { doc.notes.first { $0.id == id } }

    /// Link a Catalog person to the note backing `fileURL` (creating the row on
    /// demand), so identifying a speaker attributes the meeting to that person.
    /// Idempotent. Used by persistent speaker identification.
    func linkPerson(_ personID: String, toFile fileURL: URL) {
        let rel = AppSettings.shared.relativePath(of: fileURL)
        let title = fileURL.deletingPathExtension().lastPathComponent
        let row = note(forRelativePath: rel, title: title, date: nil)
        setPerson(personID, on: row.id, true)
    }

    /// Whether a note's backing Markdown file still exists on disk. Catalog rows
    /// only reference files by path, so a file deleted in Finder leaves a stale
    /// row until reconciled.
    func fileExists(_ note: CatalogNote) -> Bool {
        FileManager.default.fileExists(atPath: url(of: note).path)
    }
    var missingNotes: [CatalogNote] { doc.notes.filter { !fileExists($0) } }

    /// Re-evaluate the view against the current filesystem. `fileExists` reads
    /// disk live, but SwiftUI only re-renders on a publish — so a file put back
    /// in Finder keeps showing "missing" until we nudge observers.
    func refresh() { objectWillChange.send() }

    /// Drop a single catalog row (its Markdown file, if any, is left untouched).
    func deleteNote(_ id: String) {
        mutate { $0.notes.removeAll { $0.id == id } }
    }

    /// Every retained recording under `<notes>/Audio/` (any accepted audio type,
    /// recursively across the dated subfolders). Unsorted — callers sort. Shared
    /// by the Recordings hub and the per-note "assign recording" picker.
    func audioRecordings() -> [URL] {
        let root = AppSettings.shared.notesFolder.appendingPathComponent("Audio", isDirectory: true)
        guard let en = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { return [] }
        var out: [URL] = []
        for case let url as URL in en where AudioFileImporter.isAccepted(url) { out.append(url) }
        return out
    }

    /// Move a recording to the Trash and clear the `gw_audio` link on its note
    /// (when known) — the safe-delete used by the Recordings hub and note editor.
    func trashRecording(at url: URL, unlinkFrom note: CatalogNote?) {
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        if let note { MeetingNotesWriter.setAudioPath("", to: self.url(of: note)) }
    }

    /// The retained recording linked to a note via its `gw_audio` front-matter,
    /// if the file still exists. Path is relative to the notes folder.
    func audioURL(of note: CatalogNote) -> URL? {
        guard let text = url(of: note).readText(),
              let rel = FrontMatter.field("gw_audio", in: text), !rel.isEmpty else { return nil }
        let url = AppSettings.shared.notesFolder.appendingPathComponent(rel)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Move a note's Markdown file to the Trash, then drop its catalog row.
    /// Recoverable (the file lands in Trash, not a hard delete). Returns whether
    /// the file was trashed; the row is removed regardless so the Catalog never
    /// keeps a row for a note the user asked to delete. Throws only if trashing
    /// fails for a file that still exists (the caller can surface the error).
    @discardableResult
    func trashNote(_ id: String) throws -> Bool {
        guard let note = note(id: id) else { return false }
        var trashed = false
        let fileURL = url(of: note)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.trashItem(at: fileURL, resultingItemURL: nil)
            trashed = true
        }
        deleteNote(id)
        return trashed
    }

    /// Reclassify a note as a dictation: write its transcript into the dictation
    /// archive (which is outside the Catalog), then trash the meeting file and
    /// drop the catalog row. For an imported clip that turned out not to be a
    /// meeting. Returns the new dictation file URL, or nil if the note/file is
    /// gone. Throws if trashing the original fails.
    @discardableResult
    func moveNoteToDictation(_ id: String) throws -> URL? {
        guard let note = note(id: id) else { return nil }
        let fileURL = url(of: note)
        guard let content = fileURL.readText() else { return nil }

        // Strip YAML front-matter (shared reader), then take the body after the
        // FIRST content divider (the "---" following the note's title/header
        // block). Using the first divider — not the last — keeps the whole
        // transcript for a regular meeting note, whose footer is itself a "---".
        var body = FrontMatter.body(content)
        if let divider = body.range(of: "\n---\n") {
            body = String(body[divider.upperBound...])
        }
        let transcript = body.trimmingCharacters(in: .whitespacesAndNewlines)

        // Duration from the note's front-matter, if present.
        var seconds = 0
        if let m = content.range(of: #"gw_duration:\s*(\d+)"#, options: .regularExpression) {
            seconds = Int(content[m].components(separatedBy: .whitespaces).last ?? "0") ?? 0
        }
        let words = transcript.split(whereSeparator: { $0.isWhitespace }).count
        let source = note.title

        let dictURL = MeetingNotesWriter.saveDictation(
            text: transcript, app: "Imported", host: source, style: "import",
            seconds: seconds, words: words)

        // Only remove the original once the dictation copy is safely written.
        guard dictURL != nil else { return nil }
        try trashNote(id)
        return dictURL
    }

    /// Remove every row whose file no longer exists on disk. Returns how many
    /// were pruned. Note files themselves are never written or deleted here.
    @discardableResult
    func pruneMissingNotes() -> Int {
        let gone = Set(missingNotes.map { $0.id })
        guard !gone.isEmpty else { return 0 }
        mutate { $0.notes.removeAll { gone.contains($0.id) } }
        return gone.count
    }

    func setTag(_ tagID: String, on noteID: String, _ on: Bool) {
        mutate { doc in
            guard let i = doc.notes.firstIndex(where: { $0.id == noteID }) else { return }
            if on { if !doc.notes[i].tagIDs.contains(tagID) { doc.notes[i].tagIDs.append(tagID) } }
            else { doc.notes[i].tagIDs.removeAll { $0 == tagID } }
        }
    }
    func setPerson(_ personID: String, on noteID: String, _ on: Bool) {
        mutate { doc in
            guard let i = doc.notes.firstIndex(where: { $0.id == noteID }) else { return }
            if on { if !doc.notes[i].personIDs.contains(personID) { doc.notes[i].personIDs.append(personID) } }
            else { doc.notes[i].personIDs.removeAll { $0 == personID } }
        }
    }
    /// Directly assign a note to an org (for internal notes with no opportunity).
    /// A note is filed under *either* a project *or* a direct org — assigning
    /// one clears the other.
    func setOrg(_ orgID: String, on noteID: String, _ on: Bool) {
        mutate { doc in
            guard let i = doc.notes.firstIndex(where: { $0.id == noteID }) else { return }
            if on {
                doc.notes[i].projectIDs.removeAll()              // mutually exclusive
                if !doc.notes[i].orgIDs.contains(orgID) { doc.notes[i].orgIDs.append(orgID) }
            } else {
                doc.notes[i].orgIDs.removeAll { $0 == orgID }
            }
        }
    }
    func setProject(_ projID: String, on noteID: String, _ on: Bool) {
        mutate { doc in
            guard let i = doc.notes.firstIndex(where: { $0.id == noteID }) else { return }
            if on {
                doc.notes[i].orgIDs.removeAll()                  // mutually exclusive with a direct org
                doc.notes[i].projectIDs = [projID]               // a note sits in one project
            } else {
                doc.notes[i].projectIDs.removeAll { $0 == projID }
            }
        }
    }

    // MARK: Bulk note operations

    /// Trash the Markdown files for several notes and drop their rows. Best
    /// effort: files that fail to trash are skipped but their rows are still
    /// removed (matching `trashNote`). Returns how many files were trashed.
    @discardableResult
    func trashNotes(_ ids: [String]) -> Int {
        var trashed = 0
        for id in ids { if (try? trashNote(id)) == true { trashed += 1 } }
        return trashed
    }

    /// Add a tag / person to every note in `ids` (idempotent per note).
    func addTag(_ tagID: String, toNotes ids: [String]) {
        let set = Set(ids)
        mutate { doc in
            for i in doc.notes.indices where set.contains(doc.notes[i].id) {
                if !doc.notes[i].tagIDs.contains(tagID) { doc.notes[i].tagIDs.append(tagID) }
            }
        }
    }
    func addPerson(_ personID: String, toNotes ids: [String]) {
        let set = Set(ids)
        mutate { doc in
            for i in doc.notes.indices where set.contains(doc.notes[i].id) {
                if !doc.notes[i].personIDs.contains(personID) { doc.notes[i].personIDs.append(personID) }
            }
        }
    }
    /// File every note in `ids` under one org or project (mutually exclusive,
    /// matching the single-note rule). Pass `.org` or `.project` scope.
    func fileNotes(_ ids: [String], underOrg orgID: String) {
        let set = Set(ids)
        mutate { doc in
            for i in doc.notes.indices where set.contains(doc.notes[i].id) {
                doc.notes[i].projectIDs.removeAll()
                doc.notes[i].orgIDs = [orgID]
            }
        }
    }
    func fileNotes(_ ids: [String], underProject projID: String) {
        let set = Set(ids)
        mutate { doc in
            for i in doc.notes.indices where set.contains(doc.notes[i].id) {
                doc.notes[i].orgIDs.removeAll()
                doc.notes[i].projectIDs = [projID]
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
            let rel = AppSettings.shared.relativePath(of: url)
            guard !known.contains(rel) else { continue }
            let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            let date = values?.creationDate ?? values?.contentModificationDate
            newRows.append(CatalogNote(filePath: rel,
                                       title: Self.displayTitle(for: url),
                                       date: date))
        }
        if !newRows.isEmpty { mutate { $0.notes.append(contentsOf: newRows) } }
        backfillTitles()
        backfillDates()
        return newRows.count
    }

    /// Repair rows that ended up without a date (e.g. created via `linkPerson`
    /// or an import with no metadata date) by reading the file's timestamp — so
    /// they stop being hidden by the notes list's time-window filter.
    private func backfillDates() {
        let root = AppSettings.shared.notesFolder
        var notes = doc.notes
        var changed = false
        for i in notes.indices where notes[i].date == nil {
            let url = root.appendingPathComponent(notes[i].filePath)
            let v = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            if let d = v?.creationDate ?? v?.contentModificationDate { notes[i].date = d; changed = true }
        }
        if changed { mutate { $0.notes = notes } }
    }

    /// Prefer a note's front-matter `title:` over its filename for display.
    static func displayTitle(for url: URL) -> String {
        let fallback = url.deletingPathExtension().lastPathComponent
        guard let text = url.readText() else { return fallback }
        return FrontMatter.title(in: text) ?? fallback
    }

    /// One-time-per-scan repair: rows still titled with the raw `Meeting_…`
    /// filename get their front-matter title, so meetings and imports read the
    /// same way. Only touches filename-titled rows whose file still exists.
    private func backfillTitles() {
        let root = AppSettings.shared.notesFolder
        var changed = false
        var notes = doc.notes
        for i in notes.indices where notes[i].title.hasPrefix("Meeting_") {
            let url = root.appendingPathComponent(notes[i].filePath)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let title = Self.displayTitle(for: url)
            if title != notes[i].title { notes[i].title = title; changed = true }
        }
        if changed { mutate { $0.notes = notes } }
    }

    /// Full text of a note file (cached lightly by path+mtime would be nicer;
    /// at personal scale a direct read is fine).
    private func body(of note: CatalogNote) -> String {
        let url = AppSettings.shared.notesFolder.appendingPathComponent(note.filePath)
        return (url.readText()) ?? ""
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
        guard let content = url.readText() else { return [] }
        let boilerplate: Set<String> = ["meeting", "ghostwriter", "dictation"]
        let applied = Set((note.tagIDs.compactMap { tag($0)?.name.lowercased() }))
        var seen = Set<String>(), out: [String] = []
        for t in FrontMatter.tags(in: content) {
            let key = t.lowercased()
            guard !boilerplate.contains(key), !applied.contains(key),
                  seen.insert(key).inserted else { continue }
            out.append(t)
        }
        return out
    }
}
