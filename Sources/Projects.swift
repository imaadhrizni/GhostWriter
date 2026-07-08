import Foundation

// MARK: - Projects
//
// User-defined buckets that isolate one context from another (WSO2, MBA, …),
// each with an optional one level of sub-buckets (WSO2 › Zain Iraq). A meeting
// is assigned to a bucket at start; its transcription glossary is scoped to
// that bucket (plus its parent) so terms from unrelated projects never bleed
// in. Cross-contamination — priming a Customer-B call with Customer-A's names —
// is worse than no glossary, so scope is the whole point.

struct Project: Codable, Identifiable, Hashable {
    var id: String              // UUID string
    var name: String
    var parentID: String?       // nil = top-level; otherwise its parent's id
    var terms: [String] = []    // manually curated seed terms for this bucket
}

/// Pure operations over a project list — no persistence, so they're trivially
/// testable. `AppSettings` owns the stored array and delegates here.
enum Projects {

    static func project(_ id: String?, in all: [Project]) -> Project? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }

    static func topLevel(in all: [Project]) -> [Project] {
        all.filter { $0.parentID == nil }
    }

    static func children(of parentID: String, in all: [Project]) -> [Project] {
        all.filter { $0.parentID == parentID }
    }

    /// A project's id chain, nearest first: [self] or [self, parent].
    /// One level of nesting, so at most two entries. Broken/looping parent
    /// links resolve to just the project itself.
    static func lineage(of id: String, in all: [Project]) -> [String] {
        guard let proj = project(id, in: all) else { return [] }
        if let parentID = proj.parentID, project(parentID, in: all) != nil {
            return [id, parentID]
        }
        return [id]
    }

    /// "WSO2 › Zain Iraq" for a child, "WSO2" for a top-level project.
    static func displayPath(of id: String, in all: [Project]) -> String {
        guard let proj = project(id, in: all) else { return "" }
        if let parent = project(proj.parentID, in: all) {
            return "\(parent.name) › \(proj.name)"
        }
        return proj.name
    }

    /// Manual seed terms for a bucket, inheriting its parent's terms, with the
    /// bucket's own terms first (they win when the prompt budget is trimmed).
    /// Deduplicated case-insensitively.
    static func manualTerms(forID id: String, in all: [Project]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for pid in lineage(of: id, in: all) {
            for term in project(pid, in: all)?.terms ?? [] {
                let t = term.trimmingCharacters(in: .whitespaces)
                guard !t.isEmpty, seen.insert(t.lowercased()).inserted else { continue }
                out.append(t)
            }
        }
        return out
    }
}
