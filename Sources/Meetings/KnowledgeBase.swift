import Foundation

// MARK: - Knowledge Base
//
// The structured half of "Ask across everything". Meeting notes are the
// unstructured corpus (retrieved via `NotesLibrary.semanticExcerpts`); this
// enum renders the Catalog — accounts, projects/opportunities, POC health, and
// people — into a compact plain-text snapshot the model can read alongside
// those excerpts. So a question like "which POCs are at risk?" or "what's the
// open pipeline for Acme?" can be answered from the graph, not just transcripts.
//
// The snapshot is intentionally terse and bounded: one line per account, an
// indented line per project (stage + value) and per POC (phase + criteria
// tally + deadline), so it stays cheap to send even for a large catalog.

@MainActor
enum KnowledgeBase {

    /// A compact textual overview of the Catalog for the AI context, optionally
    /// scoped to a single org (with its descendants) or project. Returns "" when
    /// the catalog is empty. Capped at `maxChars` so a huge catalog can't blow
    /// the token budget — accounts are emitted most-recently-relevant first.
    static func catalogSnapshot(orgID: String? = nil, projectID: String? = nil,
                                maxChars: Int = 6_000) -> String {
        let store = CatalogStore.shared

        // Which orgs to describe. A project scope narrows to that project's org.
        let orgs: [CatalogOrg]
        if let projectID, let org = store.org(forProject: projectID) {
            orgs = [org]
        } else if let orgID {
            let ids = store.orgSubtree(of: orgID)
            orgs = store.doc.orgs.filter { ids.contains($0.id) }.sortedByName
        } else {
            orgs = store.doc.orgs.sortedByName
        }
        guard !orgs.isEmpty || !store.doc.people.isEmpty else { return "" }

        var out = "=== Knowledge Base: Accounts, Opportunities & POCs ===\n"
        for org in orgs {
            var line = "Account: \(org.name)"
            if org.relationship != .root { line += " (\(org.relationship.label))" }
            out += line + "\n"

            for project in store.projects(forOrg: org.id) where !project.archived {
                if let projectID, project.id != projectID { continue }
                var pl = "  • \(project.name) — \(project.stage.label)"
                if let v = project.valueCents { pl += ", \(money(v, project.currency))" }
                out += pl + "\n"
                for poc in project.pocs {
                    out += "      POC \"\(poc.name)\" — \(poc.phase.label)"
                    if poc.total > 0 {
                        out += ", \(poc.passed)/\(poc.total) passed"
                        if poc.failed > 0 { out += ", \(poc.failed) failed" }
                        if poc.blocked > 0 { out += ", \(poc.blocked) blocked" }
                        if poc.isAtRisk { out += " ⚠︎ at risk" }
                    }
                    if let d = poc.deadline { out += ", due \(Self.dayFormatter.string(from: d))" }
                    out += "\n"
                }
            }
            if out.count > maxChars { break }
        }

        // People — a compact roster, scoped to the same accounts as above so a
        // project/org-scoped Ask doesn't leak (or waste budget on) the whole
        // company. Unscoped Ask lists everyone. People are linked to orgs only
        // through the notes they appear on (`peopleFromNotes`).
        let people: [CatalogPerson]
        if orgID != nil || projectID != nil {
            var seen = Set<String>()
            people = orgs.flatMap { store.peopleFromNotes(forOrg: $0.id) }
                .filter { seen.insert($0.id).inserted }
        } else {
            people = store.doc.people.sortedByName
        }
        if !people.isEmpty, out.count < maxChars {
            let roster = people.prefix(60).map { p -> String in
                var s = p.name
                if let d = p.designation, !d.isEmpty { s += " (\(d))" }
                return s
            }.joined(separator: "; ")
            out += "\nPeople: \(roster)\n"
        }

        return String(out.prefix(maxChars))
    }

    // MARK: - Helpers

    /// "yyyy-MM-dd" for POC deadlines in the snapshot.
    private static let dayFormatter = DateDisplay.posixFormatter("yyyy-MM-dd")

    /// Format cents in a currency for the snapshot (e.g. 12_000_00 → "$120,000").
    private static func money(_ cents: Int, _ currency: String) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currency
        f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: Double(cents) / 100)) ?? "\(cents / 100)"
    }
}
