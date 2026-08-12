import SwiftUI
import AppKit

// MARK: - API Usage Log Window
//
// The full, per-call view of Groq API usage: every chat and transcription
// request with its feature ("where"), model ("which"), time ("when"), tokens or
// audio, and estimated cost. Backed by APIUsageLog. Includes at-a-glance
// breakdowns by feature and by model, a filter, and a clear.

final class APIUsageLogWindowController: NSWindowController {
    private static var shared: APIUsageLogWindowController?

    static func present() {
        if let existing = shared, existing.window?.isVisible == true {
            existing.bringToFront(); return
        }
        let controller = APIUsageLogWindowController()
        shared = controller
        controller.bringToFront()
    }

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.center()
        window.title = "Groq API Usage"
        window.titlebarAppearsTransparent = true
        self.init(window: window)
        window.contentView = NSHostingView(rootView: APIUsageLogView())
    }
}

private struct APIUsageLogView: View {
    @State private var entries: [APIUsageLog.Entry] = []
    @State private var scope: Scope = .all
    @State private var sourceFilter = "All features"
    @State private var confirmingClear = false

    enum Scope: String, CaseIterable, Identifiable {
        case all = "All", chat = "Chat", transcription = "Transcription"
        var id: String { rawValue }
    }

    private var sources: [String] {
        ["All features"] + Array(Set(entries.map(\.source))).sorted()
    }

    private var filtered: [APIUsageLog.Entry] {
        entries.filter { e in
            (scope == .all
             || (scope == .chat && e.kind == .chat)
             || (scope == .transcription && e.kind == .transcription))
            && (sourceFilter == "All features" || e.source == sourceFilter)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            summary
            Divider()
            controls
            Divider()
            if filtered.isEmpty {
                ContentUnavailableView("No API calls logged",
                    systemImage: "arrow.left.arrow.right",
                    description: Text("Groq chat and transcription requests will appear here as you use the app."))
            } else {
                table
            }
        }
        .frame(minWidth: 640, minHeight: 480)
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: APIUsageLog.didLog)) { _ in reload() }
    }

    // MARK: Summary + breakdowns

    private var summary: some View {
        let total = filtered.count
        let cost = filtered.reduce(0) { $0 + $1.costUSD }
        let failures = filtered.filter { !$0.ok }.count
        return HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(total) calls").font(.title2).bold()
                Text("\(UsageStats.currency(cost)) estimated" + (failures > 0 ? " · \(failures) failed" : ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
            breakdown(title: "By feature", rows: APIUsageLog.shared.totals { $0.source })
            breakdown(title: "By model", rows: APIUsageLog.shared.totals { $0.model })
            Spacer()
        }
        .padding(14)
    }

    private func breakdown(title: String, rows: [(key: String, count: Int, cost: Double)]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).bold().foregroundStyle(.secondary)
            ForEach(rows.prefix(4), id: \.key) { r in
                Text("\(r.key) — \(r.count) · \(UsageStats.currency(r.cost))")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: 240, alignment: .leading)
    }

    // MARK: Controls

    private var controls: some View {
        HStack {
            Picker("", selection: $scope) {
                ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 260)
            Picker("", selection: $sourceFilter) {
                ForEach(sources, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden().frame(width: 180)
            Spacer()
            Button("Clear…", role: .destructive) { confirmingClear = true }
                .disabled(entries.isEmpty)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .confirmationDialog("Clear the entire API usage log?",
                            isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Clear Log", role: .destructive) { APIUsageLog.shared.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the per-call history only. Your aggregate usage counters and cost estimate in Usage & Cost are unaffected.")
        }
    }

    // MARK: Table

    private var table: some View {
        Table(filtered) {
            TableColumn("When") { e in
                Text(e.date.formatted(date: .abbreviated, time: .shortened))
                    .foregroundStyle(e.ok ? .primary : .secondary)
            }
            TableColumn("Feature") { e in
                HStack(spacing: 4) {
                    if !e.ok { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                    Text(e.source)
                }
            }
            TableColumn("Kind") { e in Text(e.kind.rawValue.capitalized) }
            TableColumn("Model") { e in Text(e.model).lineLimit(1).truncationMode(.middle) }
            TableColumn("Detail") { e in
                if e.kind == .chat {
                    Text("\(e.inputTokens) in / \(e.outputTokens) out").monospacedDigit()
                } else {
                    Text(UsageStats.hoursMinutes(Int(e.audioSeconds.rounded()))).monospacedDigit()
                }
            }
            TableColumn("Est. cost") { e in
                Text(String(format: "$%.4f", e.costUSD)).monospacedDigit()
            }
        }
    }

    private func reload() { entries = APIUsageLog.shared.entries }
}
