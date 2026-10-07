import SwiftUI
import Combine
import AppKit
import UniformTypeIdentifiers

// MARK: - Debug Log View
//
// The Settings → Diagnostics window onto `FileLog`: the persistent diagnostic
// log, filterable by level and category, with Copy / Export / Reveal / Clear and
// the Verbose-logging switch. Reads the file on appear, on filter change, on
// Refresh, and every few seconds while visible (so it can be left open while
// reproducing a problem).

struct DebugLogView: View {
    @ObservedObject private var settings = AppSettings.shared

    @State private var lines: [String] = []
    @State private var minLevel: FileLog.Level = .info
    @State private var category = Self.allCategories
    @State private var diskBytes = 0
    @State private var status: String?

    private static let allCategories = "All categories"
    private static let tail = 400
    private let refresh = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Verbose logging", isOn: $settings.verboseLogging)
            Text("Adds debug-level detail — per-call API timings and segment events. Off by default to keep the log small. The log records metadata only (status codes, sizes, timings), never transcript text or your API key.")
                .font(.caption).foregroundColor(.secondary)

            HStack {
                Picker("Show", selection: $minLevel) {
                    ForEach(FileLog.Level.allCases, id: \.self) { level in
                        Text(level == .debug ? "Everything" : "\(level.title)+").tag(level)
                    }
                }
                .frame(maxWidth: 200)
                Picker("Category", selection: $category) {
                    Text(Self.allCategories).tag(Self.allCategories)
                    ForEach(FileLog.categories, id: \.self) { Text($0).tag($0) }
                }
                .frame(maxWidth: 220)
                Spacer()
                Button("Refresh", action: reload)
            }

            logBox

            HStack {
                Button("Copy") { Clipboard.plain(lines.joined(separator: "\n")); status = "Copied \(lines.count) lines" }
                    .disabled(lines.isEmpty)
                Button("Export…", action: export)
                Button("Reveal in Finder") { NSWorkspace.shared.open(FileLog.shared.folderURL) }
                Spacer()
                Button("Clear Log", role: .destructive) {
                    FileLog.shared.clear()
                    reload()
                    status = "Log cleared"
                }
            }

            Text(footer)
                .font(.caption2).foregroundColor(.secondary)
        }
        .onAppear(perform: reload)
        .onChange(of: minLevel) { _, _ in reload() }
        .onChange(of: category) { _, _ in reload() }
        .onChange(of: settings.verboseLogging) { _, _ in reload() }
        .onReceive(refresh) { _ in reload() }
    }

    // MARK: Log box

    private var logBox: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if lines.isEmpty {
                    Text("Nothing logged at this level yet.")
                        .font(.caption).foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                } else {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundColor(color(for: line))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                    .padding(8)
                }
            }
            .frame(height: 260)
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
            .onChange(of: lines.count) { _, count in
                if count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
            }
        }
    }

    private func color(for line: String) -> Color {
        if line.contains("[ERROR]") { return .red }
        if line.contains("[WARN ]") { return .orange }
        if line.contains("[DEBUG]") { return .secondary }
        return .primary
    }

    private var footer: String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(diskBytes), countStyle: .file)
        let note = status.map { " · \($0)" } ?? ""
        return "\(FileLog.shared.currentURL.path) · \(size) on disk · showing last \(lines.count)\(note)"
    }

    // MARK: Actions

    private func reload() {
        let cat = category == Self.allCategories ? nil : category
        lines = FileLog.shared.recentLines(limit: Self.tail, minLevel: minLevel, category: cat)
        diskBytes = FileLog.shared.diskUsage()
    }

    private func export() {
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? AppSettings.shared.notesFolder
        status = FilePanels.save(defaultName: "GhostWriter-log.txt",
                                 contentTypes: [.plainText],
                                 directory: desktop,
                                 successVerb: "Exported",
                                 failVerb: "Export") { url in
            try FileLog.shared.fullText().write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
