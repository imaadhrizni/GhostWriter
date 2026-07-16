import AppKit
import UniformTypeIdentifiers

// MARK: - POC export
//
// Turns a single POC (or a whole filtered set) into a clean, shareable document:
// Markdown for the clipboard or a `.md` file, and a paginated PDF via
// `MarkdownPDF`. The criteria hierarchy is emitted as a nested checklist
// (`- [x]` passed, `- [-]` failed, `- [ ]` pending), which the PDF renderer
// draws with checkbox glyphs and indented sub-criteria.
//
// All rendering is offline and pure; only the save/copy/export entry points
// touch AppKit panels and the pasteboard.

enum PocExport {

    // MARK: Markdown builders

    /// Pre-order (parent-before-children) flattening of a POC's criteria tree,
    /// each tagged with its depth — the order shown in the tracker.
    static func orderedCriteria(_ poc: Poc) -> [(criterion: PocCriterion, depth: Int)] {
        var out: [(PocCriterion, Int)] = []
        func walk(_ parent: String?, _ depth: Int) {
            for c in poc.criteria where c.parentID == parent {
                out.append((c, depth))
                walk(c.id, depth + 1)
            }
        }
        walk(nil, 0)
        return out
    }

    private static func isLeaf(_ c: PocCriterion, in poc: Poc) -> Bool {
        !poc.criteria.contains { $0.parentID == c.id }
    }

    /// A nested Markdown checklist for the criteria. Parents (groupings) render
    /// as plain bullets with a roll-up count; leaves render as checkboxes.
    private static func criteriaChecklist(_ poc: Poc) -> String {
        orderedCriteria(poc).map { node in
            let indent = String(repeating: "  ", count: node.depth)
            let c = node.criterion
            let line: String
            if isLeaf(c, in: poc) {
                let box: String
                switch c.status { case .pass: box = "[x]"; case .fail: box = "[-]"; case .pending: box = "[ ]" }
                line = "\(indent)- \(box) \(c.text)"
            } else {
                let kids = leafTally(under: c, in: poc)
                line = "\(indent)- **\(c.text)** — \(kids.passed)/\(kids.total) passed"
            }
            // Description (when present) as an indented italic sub-line.
            guard !c.detail.isEmpty else { return line }
            let detail = c.detail.replacingOccurrences(of: "\n", with: " ")
            return "\(line)\n\(indent)  _\(detail)_"
        }.joined(separator: "\n")
    }

    /// Passed/total over a parent's descendant leaves.
    private static func leafTally(under c: PocCriterion, in poc: Poc) -> (passed: Int, total: Int) {
        var stack = [c.id]; var leaves: [PocCriterion] = []
        while let id = stack.popLast() {
            let kids = poc.criteria.filter { $0.parentID == id }
            if kids.isEmpty { if let l = poc.criteria.first(where: { $0.id == id }) { leaves.append(l) } }
            else { stack.append(contentsOf: kids.map(\.id)) }
        }
        return (leaves.filter { $0.status == .pass }.count, leaves.count)
    }

    private static func dateStr(_ d: Date?) -> String? {
        d.map { $0.formatted(date: .abbreviated, time: .omitted) }
    }

    /// Full Markdown document for one POC — metadata, timeline, progress, and the
    /// criteria checklist. `accountPath` is the resolved org › project lineage.
    static func markdown(project: CatalogProject, poc: Poc, accountPath: String) -> String {
        // No leading "# name" — MarkdownPDF renders the title as its header block,
        // and a lone body heading keeps the single-POC PDF free of a redundant TOC.
        var s = ""
        var meta: [String] = []
        meta.append("- **Account:** \(accountPath)")
        meta.append("- **Status:** \(poc.phase.label)")
        if let d = dateStr(poc.startDate) { meta.append("- **Start:** \(d)") }
        if let d = dateStr(poc.deadline) { meta.append("- **Target:** \(d)") }
        let total = poc.total
        if total > 0 {
            let pct = Int((Double(poc.passed) / Double(total) * 100).rounded())
            meta.append("- **Progress:** \(poc.passed)/\(total) passed (\(pct)%)" +
                        (poc.failed > 0 ? " · \(poc.failed) failed" : ""))
        }
        s += meta.joined(separator: "\n") + "\n\n"
        if !poc.detail.trimmingCharacters(in: .whitespaces).isEmpty {
            s += poc.detail.trimmingCharacters(in: .whitespaces) + "\n\n"
        }
        s += "## Success Criteria\n\n"
        s += poc.criteria.isEmpty ? "_No criteria yet._\n" : criteriaChecklist(poc) + "\n"
        return s
    }

    /// A roll-up document for many POCs: a summary line, then each POC as a
    /// section. Used by the tracker's "Export all" over the current filter.
    static func markdown(_ items: [(project: CatalogProject, poc: Poc, accountPath: String)],
                         title: String) -> String {
        let pocs = items.map(\.poc)
        let totalCrit = pocs.reduce(0) { $0 + $1.total }
        let passed = pocs.reduce(0) { $0 + $1.passed }
        // Title comes from MarkdownPDF's header block; each POC is a "## " section
        // so the multi-POC report gets a clean Table of Contents.
        var s = ""
        var summary = ["- **POCs:** \(items.count)"]
        if totalCrit > 0 {
            let pct = Int((Double(passed) / Double(totalCrit) * 100).rounded())
            summary.append("- **Criteria passed:** \(passed)/\(totalCrit) (\(pct)%)")
        }
        let atRisk = pocs.filter { $0.total > 0 && $0.isAtRisk }.count
        if atRisk > 0 { summary.append("- **At risk:** \(atRisk)") }
        s += summary.joined(separator: "\n") + "\n\n"
        for item in items {
            let poc = item.poc
            s += "## \(poc.name)\n\n"
            var meta = ["- **Account:** \(item.accountPath)", "- **Status:** \(poc.phase.label)"]
            if let d = dateStr(poc.deadline) { meta.append("- **Target:** \(d)") }
            if poc.total > 0 { meta.append("- **Progress:** \(poc.passed)/\(poc.total) passed") }
            s += meta.joined(separator: "\n") + "\n\n"
            if !poc.detail.trimmingCharacters(in: .whitespaces).isEmpty {
                s += poc.detail.trimmingCharacters(in: .whitespaces) + "\n\n"
            }
            if !poc.criteria.isEmpty { s += criteriaChecklist(poc) + "\n\n" }
        }
        return s
    }

    // MARK: Side effects (clipboard / files)

    /// Copy Markdown to the pasteboard as both rich text (RTF) and plain string.
    @discardableResult
    static func copy(_ markdown: String) -> String {
        Clipboard.markdown(markdown)
        return "Copied to clipboard."
    }

    /// Save Markdown to a `.md` file chosen by the user.
    @discardableResult
    static func saveMarkdown(_ markdown: String, base: String) -> String {
        FilePanels.save(defaultName: base + ".md",
                        contentTypes: [UTType(filenameExtension: "md") ?? .plainText]) {
            try markdown.write(to: $0, atomically: true, encoding: .utf8)
        } ?? ""
    }

    /// Prepend a top-level heading — used for copy/save (where the title isn't
    /// carried by a PDF header block) so pasted/opened Markdown names the POC.
    static func titled(_ doc: String, _ title: String) -> String {
        "# \(title)\n\n" + doc
    }

    /// A filesystem-safe file-name base from a POC/title string.
    static func fileBase(_ s: String) -> String {
        let cleaned = s.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|")).joined(separator: "-")
        let trimmed = cleaned.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "POC" : trimmed
    }
}
