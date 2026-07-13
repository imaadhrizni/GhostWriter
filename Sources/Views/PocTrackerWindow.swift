import SwiftUI
import AppKit

// MARK: - POC / Success-Criteria Tracker
//
// A sales engineer runs a proof-of-concept against agreed success criteria and
// needs to know, at a glance, where each stands across several meetings. This
// window hangs POC criteria off a Catalog opportunity: add the criteria, then
// cycle each pending → passed → failed as the evaluation progresses. State
// lives in Catalog.json (per opportunity), so it persists and travels with the
// rest of the catalog.

final class PocTrackerWindowController: NSWindowController {
    private static var shared: PocTrackerWindowController?

    static func present() {
        if let existing = shared, existing.window?.isVisible == true {
            existing.bringToFront(); return
        }
        let controller = PocTrackerWindowController()
        shared = controller
        controller.bringToFront()
    }

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.center()
        window.title = "POC Tracker"
        window.titlebarAppearsTransparent = true
        super.init(window: window)
        window.contentView = NSHostingView(rootView: PocTrackerView())
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}

// MARK: - View

private struct PocTrackerView: View {
    @ObservedObject private var store = CatalogStore.shared
    @State private var selectedOppID: String = ""
    @State private var newCriterion = ""

    private var opportunities: [CatalogOpportunity] {
        store.doc.opportunities.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var opp: CatalogOpportunity? {
        store.opportunity(selectedOppID) ?? opportunities.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if opportunities.isEmpty {
                emptyCatalog
            } else if let opp {
                criteriaList(for: opp)
                addBar(for: opp)
            }
        }
        .padding(18)
        .frame(minWidth: 460, minHeight: 420)
        .onAppear { if selectedOppID.isEmpty { selectedOppID = opportunities.first?.id ?? "" } }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "flask").foregroundStyle(.tint)
                Text("POC Tracker").font(.title3.weight(.semibold))
                Spacer()
            }
            if !opportunities.isEmpty {
                Picker("Opportunity", selection: $selectedOppID) {
                    ForEach(opportunities) { o in
                        Text(oppLabel(o)).tag(o.id)
                    }
                }
                .labelsHidden()
                if let opp { progress(for: opp) }
            }
        }
    }

    /// "Opportunity — Project / Org" so it's clear which deal this POC is for.
    private func oppLabel(_ o: CatalogOpportunity) -> String {
        if let pid = o.projectID, let proj = store.project(pid) {
            if let oid = proj.orgID, let org = store.org(oid) {
                return "\(o.name) — \(org.name)"
            }
            return "\(o.name) — \(proj.name)"
        }
        return o.name
    }

    @ViewBuilder
    private func progress(for opp: CatalogOpportunity) -> some View {
        let total = opp.pocCriteria.count
        let passed = opp.pocCriteria.filter { $0.status == .pass }.count
        let failed = opp.pocCriteria.filter { $0.status == .fail }.count
        if total > 0 {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 12) {
                    Text("\(passed)/\(total) passed").font(.subheadline.weight(.medium))
                    if failed > 0 { Text("\(failed) failed").font(.subheadline).foregroundStyle(.red) }
                    Spacer()
                    if passed == total {
                        Label("All criteria met", systemImage: "checkmark.seal.fill").font(.caption).foregroundStyle(.green)
                    }
                }
                ProgressView(value: Double(passed), total: Double(total))
                    .tint(passed == total ? .green : .accentColor)
            }
        }
    }

    @ViewBuilder
    private func criteriaList(for opp: CatalogOpportunity) -> some View {
        if opp.pocCriteria.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "checklist").font(.largeTitle).foregroundStyle(.secondary)
                Text("No success criteria yet").foregroundStyle(.secondary)
                Text("Add the measurable outcomes this POC must prove.").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(opp.pocCriteria) { c in
                        HStack(alignment: .top, spacing: 10) {
                            Button { store.setPocStatus(c.status.next, criterionID: c.id, oppID: opp.id) } label: {
                                Image(systemName: statusIcon(c.status))
                                    .foregroundStyle(statusColor(c.status))
                                    .font(.system(size: 16))
                            }
                            .buttonStyle(.plain)
                            .help("Click to cycle: Pending → Passed → Failed")

                            Text(c.text)
                                .strikethrough(c.status == .pass, color: .secondary)
                                .foregroundStyle(c.status == .fail ? Color.red : .primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)

                            Text(c.status.label)
                                .font(.caption).foregroundStyle(statusColor(c.status))

                            Button { store.removePocCriterion(c.id, from: opp.id) } label: {
                                Image(systemName: "xmark.circle").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain).help("Remove criterion")
                        }
                        .padding(.vertical, 8)
                        Divider()
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func addBar(for opp: CatalogOpportunity) -> some View {
        HStack(spacing: 8) {
            TextField("Add a success criterion…", text: $newCriterion)
                .textFieldStyle(.roundedBorder)
                .onSubmit { commitAdd(to: opp) }
            Button("Add") { commitAdd(to: opp) }
                .disabled(newCriterion.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private var emptyCatalog: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.line.uptrend.xyaxis").font(.largeTitle).foregroundStyle(.secondary)
            Text("No opportunities yet").foregroundStyle(.secondary)
            Text("Create an opportunity in the Catalog, then track its POC here.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func commitAdd(to opp: CatalogOpportunity) {
        store.addPocCriterion(newCriterion, to: opp.id)
        newCriterion = ""
    }

    private func statusIcon(_ s: PocStatus) -> String {
        switch s {
        case .pending: return "circle"
        case .pass:    return "checkmark.circle.fill"
        case .fail:    return "xmark.circle.fill"
        }
    }

    private func statusColor(_ s: PocStatus) -> Color {
        switch s {
        case .pending: return .secondary
        case .pass:    return .green
        case .fail:    return .red
        }
    }
}
