import Foundation

// Extracted from Catalog.swift to keep CatalogStore readable. Behavior is
// unchanged — these are the same members, just grouped by concern.

// MARK: - CatalogStore · POC records & success criteria

extension CatalogStore {
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
            // Log a burndown point whenever this edit moved the tally. Cheap and
            // idempotent — `recordSnapshot` no-ops when nothing measurable changed.
            doc.projects[pi].pocs[mi].recordSnapshot(on: Date())
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
}
