import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - POC PDF export (beautiful, native SwiftUI render)
//
// A designed proof-of-concept document: a gradient banner, KPI tiles, a progress
// bar, and a hierarchical, status-colour-coded criteria list. Rendered with
// SwiftUI and tiled to PDF via `ViewPDF` (same path as the Reports builder), so
// it comes out crisp, colourful, and correctly paginated.

/// Pure, store-independent data for one POC section.
struct PocDocSection: Identifiable {
    let id = UUID()
    let name: String
    let phase: PocPhase
    let account: String
    let detail: String
    let startDate: Date?
    let deadline: Date?
    let passed: Int
    let total: Int
    let failed: Int
    let criteria: [PocDocCrit]
}

struct PocDocCrit: Identifiable {
    let id = UUID()
    let text: String
    let detail: String
    let depth: Int
    let isLeaf: Bool
    let status: PocStatus
    let rollupPassed: Int
    let rollupTotal: Int
}

/// A whole POC document — one section (single POC) or many (a filtered set).
struct PocDocData {
    let title: String
    let subtitle: String
    let summary: [(label: String, value: String, tint: Color)]
    let sections: [PocDocSection]
    let multi: Bool
}

// MARK: - Builders

enum PocDocBuilder {

    private static func crits(_ poc: Poc) -> [PocDocCrit] {
        PocExport.orderedCriteria(poc).map { node in
            let c = node.criterion
            let leaf = !poc.criteria.contains { $0.parentID == c.id }
            var rp = 0, rt = 0
            if !leaf {
                var stack = [c.id]
                while let id = stack.popLast() {
                    let kids = poc.criteria.filter { $0.parentID == id }
                    if kids.isEmpty {
                        if let l = poc.criteria.first(where: { $0.id == id }) { rt += 1; if l.status == .pass { rp += 1 } }
                    } else { stack.append(contentsOf: kids.map(\.id)) }
                }
            }
            return PocDocCrit(text: c.text, detail: c.detail, depth: node.depth, isLeaf: leaf,
                              status: c.status, rollupPassed: rp, rollupTotal: rt)
        }
    }

    private static func section(_ project: CatalogProject, _ poc: Poc, account: String) -> PocDocSection {
        PocDocSection(name: poc.name, phase: poc.phase, account: account, detail: poc.detail,
                      startDate: poc.startDate, deadline: poc.deadline,
                      passed: poc.passed, total: poc.total, failed: poc.failed, criteria: crits(poc))
    }

    static func single(project: CatalogProject, poc: Poc, accountPath: String) -> PocDocData {
        let s = section(project, poc, account: accountPath)
        var summary: [(String, String, Color)] = []
        if s.total > 0 {
            let pct = Int((Double(s.passed) / Double(s.total) * 100).rounded())
            summary.append(("Criteria passed", "\(s.passed)/\(s.total)", .cyan))
            summary.append(("Progress", "\(pct)%", pct == 100 ? .green : .blue))
        }
        if s.failed > 0 { summary.append(("Failed", "\(s.failed)", .red)) }
        summary.append(("Status", poc.phase.label, poc.phase.tint))
        if let d = poc.deadline { summary.append(("Target", d.formatted(date: .abbreviated, time: .omitted), deadlineTint(d))) }
        return PocDocData(title: poc.name, subtitle: accountPath, summary: summary, sections: [s], multi: false)
    }

    static func report(_ items: [(project: CatalogProject, poc: Poc, accountPath: String)],
                       title: String) -> PocDocData {
        let sections = items.map { section($0.project, $0.poc, account: $0.accountPath) }
        let totalCrit = sections.reduce(0) { $0 + $1.total }
        let passed = sections.reduce(0) { $0 + $1.passed }
        let atRisk = items.filter { $0.poc.total > 0 && $0.poc.isAtRisk }.count
        var summary: [(String, String, Color)] = [("POCs", "\(items.count)", .cyan)]
        if totalCrit > 0 {
            let pct = Int((Double(passed) / Double(totalCrit) * 100).rounded())
            summary.append(("Criteria passed", "\(passed)/\(totalCrit)", .blue))
            summary.append(("Overall", "\(pct)%", pct == 100 ? .green : .teal))
        }
        if atRisk > 0 { summary.append(("At risk", "\(atRisk)", .red)) }
        let sub = "\(items.count) proof\(items.count == 1 ? "" : "s") of concept"
        return PocDocData(title: title, subtitle: sub, summary: summary, sections: sections, multi: true)
    }

    static func deadlineTint(_ d: Date) -> Color {
        DeadlineState(d).map { $0.color } ?? .secondary
    }
}

// MARK: - Render view

struct PocDocView: View {
    let data: PocDocData

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in b }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Blocks for the block-based PDF pager: banner, KPI grid, then per-section
    /// content broken down finely (single POC → each criterion row is its own
    /// block; multi → each POC card is a block) so nothing is split mid-content.
    var blocks: [AnyView] {
        var out: [AnyView] = [AnyView(banner)]
        if !data.summary.isEmpty { out.append(AnyView(kpiGrid(data.summary))) }
        for (idx, s) in data.sections.enumerated() {
            if data.multi {
                out.append(AnyView(sectionCard(s, index: idx + 1)))
            } else {
                if s.startDate != nil || s.deadline != nil { out.append(AnyView(timelineRow(s))) }
                if s.total > 0 { out.append(AnyView(progressBar(s))) }
                let detail = s.detail.trimmingCharacters(in: .whitespaces)
                if !detail.isEmpty {
                    out.append(AnyView(Text(detail).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)))
                }
                out.append(AnyView(criteriaHeader))
                if s.criteria.isEmpty {
                    out.append(AnyView(Text("No criteria yet.").font(.callout).foregroundStyle(.secondary)))
                } else {
                    for (i, c) in s.criteria.enumerated() {
                        out.append(AnyView(VStack(spacing: 0) {
                            criterionRow(c)
                            if i < s.criteria.count - 1 { Divider().opacity(0.35) }
                        }))
                    }
                }
            }
        }
        return out
    }

    // Gradient title banner.
    private var banner: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "flask.fill").font(.system(size: 26)).foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 4) {
                Text(data.title).font(.largeTitle.bold()).foregroundStyle(.white)
                Text(data.subtitle).font(.subheadline).foregroundStyle(.white.opacity(0.9))
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LinearGradient(colors: [.cyan, .teal, .blue],
                                   startPoint: .topLeading, endPoint: .bottomTrailing))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // A per-POC card used in the multi-POC report.
    private func sectionCard(_ s: PocDocSection, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("\(index)").font(.caption.bold().monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.gray.opacity(0.12)))
                Text(s.name).font(.title3.bold())
                PhaseTag(phase: s.phase)
                Spacer(minLength: 0)
                if let d = s.deadline { DeadlineTag(deadline: d) }
            }
            Text(s.account).font(.caption).foregroundStyle(.secondary)
            if s.total > 0 { progressBar(s) }
            if !s.detail.trimmingCharacters(in: .whitespaces).isEmpty {
                Text(s.detail.trimmingCharacters(in: .whitespaces))
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            criteriaList(s)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.gray.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.gray.opacity(0.14)))
    }

    private func timelineRow(_ s: PocDocSection) -> some View {
        HStack(spacing: 10) {
            PhaseTag(phase: s.phase)
            if let d = s.startDate { chip("Start", d.formatted(date: .abbreviated, time: .omitted), .secondary) }
            if let d = s.deadline {
                Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                chip("Target", d.formatted(date: .abbreviated, time: .omitted), PocDocBuilder.deadlineTint(d))
                DeadlineTag(deadline: d)
            }
            Spacer(minLength: 0)
        }
    }

    private func chip(_ label: String, _ value: String, _ tint: Color) -> some View {
        HStack(spacing: 4) {
            Text(label.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).kerning(0.3)
            Text(value).font(.caption.weight(.medium)).foregroundStyle(tint)
        }
        .pillBackground(tint, opacity: 0.12, hPad: 8, vPad: 4)
    }

    private func progressBar(_ s: PocDocSection) -> some View {
        let pct = s.total == 0 ? 0 : Double(s.passed) / Double(s.total)
        let tint: Color = s.failed > 0 ? .orange : (pct == 1 ? .green : .blue)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(s.passed) of \(s.total) passed").font(.caption.weight(.medium))
                if s.failed > 0 { Text("· \(s.failed) failed").font(.caption).foregroundStyle(.red) }
                Spacer()
                Text("\(Int((pct * 100).rounded()))%").font(.caption.bold().monospacedDigit()).foregroundStyle(tint)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.gray.opacity(0.15))
                    Capsule().fill(tint.gradient).frame(width: max(4, geo.size.width * pct))
                }
            }
            .frame(height: 8)
        }
    }

    private func kpiGrid(_ items: [(label: String, value: String, tint: Color)]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: 10)], alignment: .leading, spacing: 10) {
            ForEach(items.indices, id: \.self) { i in
                let tint = items[i].tint
                HStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: 2).fill(tint).frame(width: 4)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(items[i].value).font(.title3.bold().monospacedDigit()).foregroundStyle(tint).lineLimit(1)
                        Text(items[i].label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .padding(10)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 9).fill(tint.opacity(0.10)))
            }
        }
    }

    // "Success Criteria" section header (single-POC layout).
    private var criteriaHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "checklist")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.cyan.gradient))
                Text("Success Criteria").font(.title2.bold())
            }
            RoundedRectangle(cornerRadius: 1).fill(Color.cyan.opacity(0.5)).frame(height: 2)
        }
    }

    // Criteria list for the multi-POC section card (kept inline in the card).
    @ViewBuilder private func criteriaList(_ s: PocDocSection) -> some View {
        if s.criteria.isEmpty {
            Text("No criteria yet.").font(.callout).foregroundStyle(.secondary)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(s.criteria.enumerated()), id: \.element.id) { i, c in
                    criterionRow(c)
                    if i < s.criteria.count - 1 { Divider().opacity(0.35) }
                }
            }
        }
    }

    private func criterionRow(_ c: PocDocCrit) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Color.clear.frame(width: CGFloat(c.depth) * 18, height: 1)
            if c.isLeaf {
                Image(systemName: c.status.icon).font(.system(size: 14)).foregroundStyle(c.status.color)
                    .frame(width: 18)
            } else {
                Image(systemName: "folder").font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 18)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(c.text)
                    .font(c.isLeaf ? .callout : .callout.weight(.semibold))
                    .strikethrough(c.isLeaf && c.status == .pass, color: .secondary)
                    .foregroundStyle(c.isLeaf && c.status == .fail ? Color.red : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                if !c.detail.isEmpty {
                    Text(c.detail)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if c.isLeaf {
                Text(c.status.label).font(.caption2.weight(.semibold)).foregroundStyle(c.status.color)
                    .pillBackground(c.status.color, opacity: 0.14, hPad: 7, vPad: 2)
            } else {
                Text("\(c.rollupPassed)/\(c.rollupTotal)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 7)
    }

}

/// A small phase pill for the PDF (independent of the interactive `PhasePill`).
private struct PhaseTag: View {
    let phase: PocPhase
    var body: some View {
        TintedPill(text: phase.label, tint: phase.tint, weight: .semibold,
                   opacity: 0.15, hPad: 8, vPad: 3)
    }
}

/// A deadline pill for the PDF.
private struct DeadlineTag: View {
    let deadline: Date
    var body: some View {
        if let st = DeadlineState(deadline) {
            TintedPill(text: st.label, tint: st.color, weight: .semibold,
                       opacity: 0.15, hPad: 8, vPad: 3)
        }
    }
}

// MARK: - Export entry point

@MainActor
enum PocPDF {
    /// Render a POC document to PDF and save where the user picks.
    @discardableResult
    static func export(_ data: PocDocData, base: String) -> String {
        let sz = AppSettings.shared.pdfPageSize
        guard let pdf = ViewPDF.data(blocks: PocDocView(data: data).blocks,
                                     pageW: sz.width, pageH: sz.height) else { return "Couldn't render PDF." }
        return FilePanels.save(defaultName: base + ".pdf", contentTypes: [.pdf],
                               successVerb: "Exported", failVerb: "Export",
                               write: { try pdf.write(to: $0) }) ?? ""
    }
}
