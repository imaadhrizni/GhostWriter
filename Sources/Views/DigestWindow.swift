import SwiftUI
import AppKit

// MARK: - Digest Window
//
// The interactive view of the proactive digest: meetings held, open (and
// overdue) action items you can tick off in place, and the Catalog
// relationships that have gone quiet. Rebuilt live each time it opens.

final class DigestWindowController: NSWindowController {
    private static var shared: DigestWindowController?

    static func present() {
        if let existing = shared, existing.window?.isVisible == true {
            existing.bringToFront(); return
        }
        let controller = DigestWindowController()
        shared = controller
        controller.bringToFront()
    }

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.center()
        window.title = "Digest"
        window.titlebarAppearsTransparent = true
        super.init(window: window)
        window.contentView = NSHostingView(rootView: DigestView())
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

}

// MARK: - View

private struct DigestView: View {
    @State private var data: DigestService.DigestData?
    /// Local "checked" overlay so ticking feels instant before the file rewrite.
    @State private var checked: Set<UUID> = []
    /// Collapsed group ids.
    @State private var collapsed: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let data {
                        if data.isEmpty {
                            emptyState
                        } else {
                            summaryLine(data)
                            ForEach(data.groups) { groupCard($0) }
                            staleSection(data)
                        }
                    } else {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                    }
                }
                .padding(20)
            }
        }
        .frame(minWidth: 420, minHeight: 400)
        .onAppear(perform: rebuild)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(data?.title ?? "Digest").font(.title2).bold()
                if let data {
                    Text(data.generatedAt.formatted(date: .complete, time: .shortened))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Picker("", selection: Binding(
                get: { AppSettings.shared.digestFrequency },
                set: { AppSettings.shared.digestFrequency = $0; rebuild() })) {
                ForEach(DigestService.Period.allCases, id: \.rawValue) { p in
                    Text(p.label).tag(p.rawValue)
                }
            }
            .labelsHidden().frame(width: 120)
            if let data, !data.groups.isEmpty {
                Button {
                    collapsed = collapsed.count == data.groups.count
                        ? [] : Set(data.groups.map(\.id))
                } label: {
                    Image(systemName: collapsed.count == data.groups.count
                          ? "rectangle.expand.vertical" : "rectangle.compress.vertical")
                }
                .help(collapsed.count == data.groups.count ? "Expand all" : "Collapse all")
            }
            Button(action: rebuild) { Image(systemName: "arrow.clockwise") }
                .help("Rebuild")
        }
        .padding(16)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle").font(.system(size: 38)).foregroundStyle(.green)
            Text("All clear").font(.headline)
            Text("No meetings, open action items, or quiet relationships in this period.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.top, 30)
    }

    // MARK: Sections

    private func summaryLine(_ d: DigestService.DigestData) -> some View {
        Text("\(d.periodMeetingCount) meeting\(d.periodMeetingCount == 1 ? "" : "s") · \(d.openActionCount) open action item\(d.openActionCount == 1 ? "" : "s")")
            .font(.callout).foregroundStyle(.secondary)
    }

    /// One relationship card: Org header (with Project › Opportunity subtitle),
    /// then each of its meetings with the meeting's action items nested.
    private func groupCard(_ g: DigestService.Group) -> some View {
        let isCollapsed = collapsed.contains(g.id)
        return VStack(alignment: .leading, spacing: 10) {
            Button {
                if isCollapsed { collapsed.remove(g.id) } else { collapsed.insert(g.id) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.caption2).foregroundStyle(.secondary).frame(width: 10)
                    Image(systemName: g.tint == "unfiled" ? "tray" : "building.2")
                        .foregroundStyle(g.tint == "unfiled" ? Color.secondary : .blue)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(g.title).font(.headline)
                        if let detail = g.detail {
                            Text(detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if g.periodCount > 0 { CountPill(text: "\(g.periodCount) mtg", tint: .blue) }
                    if g.overdueCount > 0 { CountPill(text: "\(g.overdueCount) overdue", tint: .red) }
                    if g.openCount > 0 { CountPill(text: "\(g.openCount) open", tint: .orange) }
                }
            }
            .buttonStyle(.plain)

            if !isCollapsed {
            ForEach(g.meetings) { m in
                VStack(alignment: .leading, spacing: 5) {
                    Button { NotesViewerWindowController.present(fileURL: m.file.url) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "doc.text").font(.caption).foregroundStyle(.tertiary)
                            Text(m.file.displayName).font(.subheadline)
                            if !m.inPeriod {
                                Text("earlier").font(.caption2).foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Image(systemName: "arrow.up.forward").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)

                    if m.hasOpen {
                        ForEach(m.overdue) { ActionRow(item: $0, overdue: true, checked: $checked) }
                        ForEach(m.open) { ActionRow(item: $0, overdue: false, checked: $checked) }
                    }
                }
                .padding(.leading, 6)
            }
            }   // end if !isCollapsed
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.28)))
    }

    @ViewBuilder
    private func staleSection(_ d: DigestService.DigestData) -> some View {
        if !d.stale.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(icon: "clock.badge.exclamationmark", tint: .purple,
                              title: "Quiet Relationships", count: d.stale.count)
                Text("No contact in \(AppSettings.shared.staleRelationshipDays)+ days")
                    .font(.caption2).foregroundStyle(.secondary)
                ForEach(d.stale) { s in
                    HStack {
                        Text(s.name).lineLimit(1)
                        Spacer()
                        Text("last: \(s.lastContact)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func rebuild() {
        checked = []
        data = DigestService.buildData(period: DigestService.period(from: AppSettings.shared.digestFrequency))
    }
}

// MARK: - Rows

private struct SectionHeader: View {
    let icon: String; let tint: Color; let title: String; let count: Int
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(title).font(.headline)
            Text("\(count)").font(.caption).monospacedDigit()
                .padding(.horizontal, 7).padding(.vertical, 1)
                .background(Capsule().fill(Color(nsColor: .quaternaryLabelColor).opacity(0.5)))
            Spacer()
        }
    }
}

private struct CountPill: View {
    let text: String; let tint: Color
    var body: some View {
        Text(text).font(.caption2).bold()
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.18)))
            .foregroundStyle(tint)
    }
}

private struct ActionRow: View {
    let item: NotesLibrary.ActionItem
    let overdue: Bool
    @Binding var checked: Set<UUID>

    private var isChecked: Bool { checked.contains(item.id) }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button {
                NotesLibrary.toggleDone(item)
                if isChecked { checked.remove(item.id) } else { checked.insert(item.id) }
            } label: {
                Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isChecked ? .green : .secondary)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.displayText)
                    .strikethrough(isChecked)
                    .foregroundStyle(isChecked ? .secondary : .primary)
                HStack(spacing: 6) {
                    if let owner = item.owner { Pill(text: "@\(owner)", tint: .blue) }
                    if let due = item.due { Pill(text: "due \(due)", tint: overdue ? .red : .secondary) }
                    Button { NotesViewerWindowController.present(fileURL: item.file.url) } label: {
                        Text(item.file.displayName).font(.caption2).foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer()
        }
    }
}

private struct Pill: View {
    let text: String; let tint: Color
    var body: some View {
        Text(text).font(.caption2)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(tint.opacity(0.15)))
            .foregroundStyle(tint)
    }
}
