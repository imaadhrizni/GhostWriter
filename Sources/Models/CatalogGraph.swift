import Foundation

// MARK: - Catalog Graph
//
// The relationship graph behind the Catalog's **Network** section: every
// organisation, project, person, tag and (optionally) note as a node, and the
// ways they're linked as edges.
//
// Structural edges come straight from the Catalog (org hierarchy, project
// ownership, a note filed under a project/org, a person or tag attached to a
// note). *Derived* edges are computed: a person or tag is linked to each
// organisation whose notes it appears in, weighted by how many notes say so —
// which is what lets people and tags connect accounts even with notes hidden.
//
// Pure value logic — no UI, no I/O, no store dependency (`CatalogStore.graphInput()`
// adapts the live Catalog to `Input`) — so it is unit-testable on its own.

struct CatalogGraph {

    // MARK: Vocabulary

    enum Kind: String, CaseIterable, Identifiable, Codable {
        case org, project, person, tag, note
        var id: String { rawValue }

        var plural: String {
            switch self {
            case .org: return "Organisations"
            case .project: return "Projects"
            case .person: return "People"
            case .tag: return "Tags"
            case .note: return "Notes"
            }
        }
        var singular: String {
            switch self {
            case .org: return "Organisation"
            case .project: return "Project"
            case .person: return "Person"
            case .tag: return "Tag"
            case .note: return "Note"
            }
        }
    }

    enum EdgeKind: String {
        case hierarchy   // organisation → child organisation
        case owns        // organisation → project, project → sub-project
        case filed       // note → the project / organisation it is filed under
        case mention     // note → a person on it
        case tagged      // note → a tag on it
        case derived     // person / tag ↔ organisation, computed from notes

        /// Spring length and stiffness used when laying the graph out. Structural
        /// links pull firmly; derived links are long and loose — they say "these
        /// are related", not "these belong together", and shouldn't drag unrelated
        /// clusters into one blob.
        var spring: (rest: Double, strength: Double) {
            switch self {
            case .hierarchy: return (95, 0.05)
            case .owns:      return (78, 0.05)
            case .mention:   return (64, 0.05)
            case .filed:     return (52, 0.05)
            case .tagged:    return (58, 0.05)
            case .derived:   return (210, 0.005)
            }
        }
    }

    /// Plain input, decoupled from the Catalog's storage types.
    struct Input {
        struct Org { var id: String; var name: String; var parentID: String?; var relationship: String; var isInternal: Bool = false }
        struct Project { var id: String; var name: String; var orgID: String?; var parentID: String?; var stage: String; var valueCents: Int? }
        struct Person { var id: String; var name: String; var designation: String }
        struct Tag { var id: String; var name: String }
        struct Note { var id: String; var title: String; var date: Date?; var projectIDs: [String]; var orgIDs: [String]; var tagIDs: [String]; var personIDs: [String] }
        var orgs: [Org] = [], projects: [Project] = [], people: [Person] = [], tags: [Tag] = [], notes: [Note] = []
    }

    struct Node: Identifiable, Hashable {
        /// `"<kind>:<refID>"` — unique across kinds.
        let id: String
        let kind: Kind
        /// The Catalog entity's own id (what the editors and lookups take).
        let refID: String
        var name: String
        var detail: String?
        /// Notes that touch this node (a project/org counts its descendants' notes).
        var noteCount = 0
        var lastNoteDaysAgo: Int?
        /// A person who appears on notes for two or more top-level organisations.
        var isConnector = false
        /// An open organisation/project with no note for a while.
        var isDormant = false
        /// Projects: "open" / "won" / "lost".
        var stage: String?
        var valueCents: Int?
        var radius: Double = 6

        static func == (a: Node, b: Node) -> Bool { a.id == b.id }
        func hash(into h: inout Hasher) { h.combine(id) }
    }

    struct Edge: Hashable {
        let a: String
        let b: String
        let kind: EdgeKind
        var weight = 1
    }

    /// Which part of the graph is on screen.
    struct Visibility: Equatable {
        var kinds: Set<Kind>
        var derived: Bool
    }

    // MARK: Storage

    private(set) var nodes: [Node] = []
    private(set) var edges: [Edge] = []
    private var index: [String: Int] = [:]
    private var adjacency: [String: [Int]] = [:]

    static func nodeID(_ kind: Kind, _ refID: String) -> String { "\(kind.rawValue):\(refID)" }

    func node(_ id: String) -> Node? { index[id].map { nodes[$0] } }
    func edges(of id: String) -> [Edge] { (adjacency[id] ?? []).map { edges[$0] } }
    func other(_ e: Edge, than id: String) -> String { e.a == id ? e.b : e.a }

    func shows(_ n: Node, _ v: Visibility) -> Bool { v.kinds.contains(n.kind) }
    func shows(_ e: Edge, _ v: Visibility) -> Bool {
        guard e.kind != .derived || v.derived,
              let a = node(e.a), let b = node(e.b) else { return false }
        return v.kinds.contains(a.kind) && v.kinds.contains(b.kind)
    }

    // MARK: Build

    init(_ input: Input = Input(), today: Date = Date(), dormantDays: Int = 45) {
        let orgByID = Dictionary(input.orgs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let projectByID = Dictionary(input.projects.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        // --- nodes
        var made: [Node] = []
        for o in input.orgs {
            made.append(Node(id: Self.nodeID(.org, o.id), kind: .org, refID: o.id, name: o.name, detail: o.relationship))
        }
        for p in input.projects {
            var n = Node(id: Self.nodeID(.project, p.id), kind: .project, refID: p.id, name: p.name, detail: p.stage.capitalized)
            n.stage = p.stage; n.valueCents = p.valueCents
            made.append(n)
        }
        for p in input.people {
            made.append(Node(id: Self.nodeID(.person, p.id), kind: .person, refID: p.id, name: p.name,
                             detail: p.designation.isEmpty ? nil : p.designation))
        }
        for t in input.tags { made.append(Node(id: Self.nodeID(.tag, t.id), kind: .tag, refID: t.id, name: t.name)) }
        for n in input.notes { made.append(Node(id: Self.nodeID(.note, n.id), kind: .note, refID: n.id, name: n.title)) }
        nodes = made
        for (i, n) in nodes.enumerated() { index[n.id] = i }

        // --- helpers over the hierarchies (bounded: a corrupt cycle can't hang us)
        func orgOfProject(_ id: String) -> String? {
            var cur = projectByID[id], guardN = 0
            while let p = cur, guardN < 32 {
                if let o = p.orgID, orgByID[o] != nil { return o }
                cur = p.parentID.flatMap { projectByID[$0] }; guardN += 1
            }
            return nil
        }
        func projectLineage(_ id: String) -> [String] {
            var out: [String] = [], cur = projectByID[id], guardN = 0
            while let p = cur, guardN < 32 { out.append(p.id); cur = p.parentID.flatMap { projectByID[$0] }; guardN += 1 }
            return out
        }
        func orgLineage(_ id: String) -> [String] {
            var out: [String] = [], cur = orgByID[id], guardN = 0
            while let o = cur, guardN < 32 { out.append(o.id); cur = o.parentID.flatMap { orgByID[$0] }; guardN += 1 }
            return out
        }
        func topOrg(_ id: String) -> String { orgLineage(id).last ?? id }

        // --- structural edges
        var made2: [Edge] = []
        func add(_ a: String, _ b: String, _ kind: EdgeKind) {
            guard index[a] != nil, index[b] != nil else { return }
            made2.append(Edge(a: a, b: b, kind: kind))
        }
        for o in input.orgs { if let p = o.parentID { add(Self.nodeID(.org, p), Self.nodeID(.org, o.id), .hierarchy) } }
        for p in input.projects {
            if let parent = p.parentID, projectByID[parent] != nil { add(Self.nodeID(.project, parent), Self.nodeID(.project, p.id), .owns) }
            else if let o = p.orgID { add(Self.nodeID(.org, o), Self.nodeID(.project, p.id), .owns) }
        }

        // --- per-note: filed/mention/tagged edges, derived links, and activity metrics
        var derivedWeight: [String: Int] = [:], derivedOrder: [(String, String)] = []
        var count: [String: Int] = [:], last: [String: Int] = [:]
        var topOrgsOfPerson: [String: Set<String>] = [:]
        let cal = Calendar(identifier: .gregorian)

        for note in input.notes {
            let nid = Self.nodeID(.note, note.id)
            for pid in note.projectIDs { add(nid, Self.nodeID(.project, pid), .filed) }
            for oid in note.orgIDs { add(nid, Self.nodeID(.org, oid), .filed) }
            for uid in note.personIDs { add(nid, Self.nodeID(.person, uid), .mention) }
            for tid in note.tagIDs { add(nid, Self.nodeID(.tag, tid), .tagged) }

            // Every project (the filed one and its ancestors) and organisation this note touches.
            var projects = Set<String>(), orgs = Set<String>()
            for pid in note.projectIDs {
                projects.formUnion(projectLineage(pid))
                if let o = orgOfProject(pid) { orgs.formUnion(orgLineage(o)) }
            }
            for oid in note.orgIDs where orgByID[oid] != nil { orgs.formUnion(orgLineage(oid)) }

            // Organisations a person/tag is *directly* tied to by this note (not ancestors).
            var directOrgs = Set<String>()
            for pid in note.projectIDs { if let o = orgOfProject(pid) { directOrgs.insert(o) } }
            for oid in note.orgIDs where orgByID[oid] != nil { directOrgs.insert(oid) }

            let ago = note.date.map { max(0, cal.dateComponents([.day], from: $0, to: today).day ?? 0) }
            var touched: [String] = [nid]
            touched += projects.map { Self.nodeID(.project, $0) }
            touched += orgs.map { Self.nodeID(.org, $0) }
            touched += note.personIDs.map { Self.nodeID(.person, $0) }
            touched += note.tagIDs.map { Self.nodeID(.tag, $0) }
            for id in touched {
                count[id, default: 0] += 1
                if let ago { last[id] = min(last[id] ?? ago, ago) }
            }

            for o in directOrgs {
                let orgNode = Self.nodeID(.org, o)
                for uid in note.personIDs {
                    let key = Self.nodeID(.person, uid) + "|" + orgNode
                    if derivedWeight[key] == nil { derivedOrder.append((Self.nodeID(.person, uid), orgNode)) }
                    derivedWeight[key, default: 0] += 1
                    topOrgsOfPerson[uid, default: []].insert(topOrg(o))
                }
                for tid in note.tagIDs {
                    let key = Self.nodeID(.tag, tid) + "|" + orgNode
                    if derivedWeight[key] == nil { derivedOrder.append((Self.nodeID(.tag, tid), orgNode)) }
                    derivedWeight[key, default: 0] += 1
                }
            }
        }
        for (a, b) in derivedOrder where index[a] != nil && index[b] != nil {
            made2.append(Edge(a: a, b: b, kind: .derived, weight: derivedWeight[a + "|" + b] ?? 1))
        }
        edges = made2
        for (i, e) in edges.enumerated() { adjacency[e.a, default: []].append(i); adjacency[e.b, default: []].append(i) }

        // --- node metrics
        let internalOrgs = Set(input.orgs.filter(\.isInternal).map { Self.nodeID(.org, $0.id) })
        for i in nodes.indices {
            let id = nodes[i].id
            nodes[i].noteCount = count[id] ?? 0
            nodes[i].lastNoteDaysAgo = last[id]
            switch nodes[i].kind {
            case .person:
                nodes[i].isConnector = (topOrgsOfPerson[nodes[i].refID]?.count ?? 0) >= 2
            case .org:
                nodes[i].isDormant = !internalOrgs.contains(id) && (last[id].map { $0 > dormantDays } ?? true)
            case .project:
                let open = nodes[i].stage == "open"
                nodes[i].isDormant = open && (last[id].map { $0 > dormantDays } ?? true)
            default: break
            }
            nodes[i].radius = Self.radius(for: nodes[i])
        }
    }

    /// Bigger where there's more activity, so busy accounts and people stand out.
    static func radius(for n: Node) -> Double {
        switch n.kind {
        case .org:     return 15 + Double(min(n.noteCount, 8)) * 1.2
        case .project: return 10 + Double(min(n.noteCount, 6))
        case .person:  return 8 + Double(min(n.noteCount, 5)) * 1.1
        case .tag:     return 7 + Double(min(n.noteCount, 5)) * 0.6
        case .note:    return 5.5
        }
    }

    // MARK: Queries

    /// Nodes within `depth` steps of `id` over the visible graph (including `id`).
    func ego(of id: String, depth: Int, _ v: Visibility) -> Set<String> {
        guard node(id) != nil else { return [] }
        var dist: [String: Int] = [id: 0], queue = [id], head = 0
        while head < queue.count {
            let cur = queue[head]; head += 1
            guard dist[cur]! < depth else { continue }
            for e in edges(of: cur) where shows(e, v) {
                let next = other(e, than: cur)
                if dist[next] == nil, let n = node(next), shows(n, v) { dist[next] = dist[cur]! + 1; queue.append(next) }
            }
        }
        return Set(dist.keys)
    }

    /// The fewest-hops route from `a` to `b` over the visible graph, or nil.
    func shortestPath(from a: String, to b: String, _ v: Visibility) -> [String]? {
        guard let na = node(a), let nb = node(b), shows(na, v), shows(nb, v) else { return nil }
        if a == b { return [a] }
        var prev: [String: String] = [:], seen: Set<String> = [a], queue = [a], head = 0
        while head < queue.count {
            let cur = queue[head]; head += 1
            for e in edges(of: cur) where shows(e, v) {
                let next = other(e, than: cur)
                guard !seen.contains(next), let n = node(next), shows(n, v) else { continue }
                seen.insert(next); prev[next] = cur
                if next == b {
                    var path = [b], at = b
                    while let p = prev[at] { path.append(p); at = p }
                    return path.reversed()
                }
                queue.append(next)
            }
        }
        return nil
    }

    /// Everything directly linked to `id`, grouped by kind — for the selection card.
    func connections(of id: String) -> [(node: Node, edge: Edge)] {
        var seen = Set<String>(), out: [(Node, Edge)] = []
        for e in edges(of: id) {
            let o = other(e, than: id)
            guard !seen.contains(o), let n = node(o) else { continue }
            seen.insert(o); out.append((n, e))
        }
        return out.sorted { ($0.0.kind.rawValue, -$0.0.noteCount, $0.0.name) < ($1.0.kind.rawValue, -$1.0.noteCount, $1.0.name) }
    }
}
