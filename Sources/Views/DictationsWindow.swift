import SwiftUI
import AppKit

// MARK: - Dictations Browser
//
// A master–detail browser over the archived dictations (the per-dictation
// Markdown files written when "Save each dictation to a file" is on). Kept
// separate from the meetings-only Catalog.
//
// Left: a searchable, app-filterable, day-grouped list with a live stats bar.
// Right: the selected dictation's full text with first-class actions — Copy,
// Open in the editor, Reveal in Finder, Move to Trash. A Select mode adds
// checkboxes for bulk Copy / Delete.

final class DictationsWindowController: NSWindowController {
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.center()
        window.title = "Dictations"
        window.setFrameAutosaveName("DictationsWindow")
        self.init(window: window)
        window.contentView = NSHostingView(rootView: DictationsView())
    }
}

// MARK: - Model

private struct DictationItem: Identifiable, Hashable {
    let url: URL
    var id: URL { url }
    let app: String
    let style: String
    let text: String       // full body
    let preview: String    // single-line snippet for the list row
    let seconds: Int
    let words: Int

    /// Compact duration: "12s" under a minute, "1:23" above.
    var durationText: String {
        guard seconds > 0 else { return "—" }
        return seconds < 60 ? "\(seconds)s" : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private var stamp: String {
        url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "Dictation_", with: "")   // yyyy-MM-dd_HH-mm-ss
    }
    var day: String { String(stamp.prefix(10)) }
    var time: String {
        stamp.count > 11 ? String(stamp.dropFirst(11)).replacingOccurrences(of: "-", with: ":") : stamp
    }
    /// "03 Jul 2026 · 14:30:22" for the detail header.
    var fullTimestamp: String { "\(DateDisplay.day(day)) · \(time)" }

    /// Parse a dictation file: front-matter `app:`/`style:`/`duration:`/`words:`
    /// plus the body. Routes through the shared FrontMatter reader.
    init(url: URL) {
        self.url = url
        let content = (url.readText()) ?? ""
        func unquote(_ s: String) -> String {
            var v = s.trimmingCharacters(in: .whitespaces)
            if v.hasPrefix("\""), v.hasSuffix("\""), v.count >= 2 {
                v = String(v.dropFirst().dropLast())
                    .replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\\\", with: "\\")
            }
            return v
        }

        self.app = FrontMatter.field("app", in: content).map(unquote) ?? ""
        self.style = FrontMatter.field("style", in: content).map(unquote) ?? ""
        self.seconds = FrontMatter.field("duration", in: content)
            .map { Int($0.replacingOccurrences(of: "s", with: "").trimmingCharacters(in: .whitespaces)) ?? 0 } ?? 0
        self.words = FrontMatter.field("words", in: content).flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 0

        let body = FrontMatter.body(content).trimmingCharacters(in: .whitespacesAndNewlines)
        self.text = body
        self.preview = body
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func loadAll(limit: Int = 500) -> [DictationItem] {
        let folder = AppSettings.shared.dictationsFolder
        // Recursive: files may live in Year/Month/Day subfolders per the
        // organization setting. The filename timestamp makes name order = date order.
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        return enumerator.compactMap { $0 as? URL }
            .filter { $0.lastPathComponent.hasPrefix("Dictation_") && $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .prefix(limit)
            .map(DictationItem.init)
    }
}

// MARK: - View

private struct DictationsView: View {
    @State private var items: [DictationItem] = []
    @State private var query = ""
    @State private var loading = false
    @State private var appFilter = ""          // "" = all apps
    @State private var newestFirst = true
    @State private var selectedID: URL?        // drives the detail pane
    @State private var copiedID: URL?          // transient "Copied!" flash

    // Bulk actions.
    @State private var selecting = false
    @State private var selected: Set<URL> = []
    @State private var pendingBulk: BulkKind?
    @State private var pendingTrash: DictationItem?
    @State private var trashError: String?

    private enum BulkKind: Identifiable { case selected, all; var id: Int { self == .all ? 1 : 0 } }

    // MARK: Derived

    private var apps: [String] {
        Array(Set(items.map { $0.app.isEmpty ? "—" : $0.app })).sorted()
    }

    private var filtered: [DictationItem] {
        let q = query.lowercased()
        var out = items.filter { item in
            (q.isEmpty
                || item.preview.lowercased().contains(q)
                || item.app.lowercased().contains(q)
                || item.style.lowercased().contains(q))
            && (appFilter.isEmpty || (item.app.isEmpty ? "—" : item.app) == appFilter)
        }
        if !newestFirst { out.reverse() }   // loadAll is newest-first
        return out
    }

    private var groups: [(day: String, items: [DictationItem])] {
        var result: [(day: String, items: [DictationItem])] = []
        for item in filtered {
            if result.last?.day == item.day { result[result.count - 1].items.append(item) }
            else { result.append((item.day, [item])) }
        }
        return result
    }

    private var selectedItem: DictationItem? {
        selectedID.flatMap { id in items.first { $0.url == id } }
    }

    private var totalSeconds: Int { filtered.reduce(0) { $0 + $1.seconds } }
    private var totalWords: Int { filtered.reduce(0) { $0 + $1.words } }

    // MARK: Body

    var body: some View {
        NavigationSplitView {
            listColumn
                .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 480)
                .navigationTitle("Dictations")
                .safeAreaInset(edge: .bottom) {
                    if !items.isEmpty {
                        VStack(spacing: 0) { Divider(); statsBar }
                            .background(.bar)
                    }
                }
        } detail: {
            detailPane
                .navigationTitle(selectedItem?.app ?? "Dictations")
        }
        .frame(minWidth: 800, minHeight: 480)
        .searchable(text: $query, placement: .sidebar, prompt: "Search text, app, or style")
        .toolbar { toolbarContent }
        .confirmationDialog(
            "Move this dictation to the Trash?",
            isPresented: Binding(get: { pendingTrash != nil }, set: { if !$0 { pendingTrash = nil } }),
            presenting: pendingTrash
        ) { item in
            Button("Move to Trash", role: .destructive) { trash(item) }
            Button("Cancel", role: .cancel) { pendingTrash = nil }
        } message: { _ in
            Text("The dictation file will be moved to the Trash. You can recover it from there.")
        }
        .confirmationDialog(
            pendingBulk == .all ? "Move all \(filtered.count) dictations to the Trash?"
                                : "Move \(selected.count) dictation\(selected.count == 1 ? "" : "s") to the Trash?",
            isPresented: Binding(get: { pendingBulk != nil }, set: { if !$0 { pendingBulk = nil } }),
            presenting: pendingBulk
        ) { kind in
            Button("Move to Trash", role: .destructive) { performBulk(kind) }
            Button("Cancel", role: .cancel) { pendingBulk = nil }
        } message: { _ in
            Text("The files will be moved to the macOS Trash. You can recover them from there.")
        }
        .alert("Couldn't delete", isPresented: Binding(get: { trashError != nil }, set: { if !$0 { trashError = nil } })) {
            Button("OK", role: .cancel) { trashError = nil }
        } message: { Text(trashError ?? "") }
        .task { await reload() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            Task { await reload() }
        }
    }

    // MARK: Toolbar (unified titlebar, like the Catalog window)

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            if selecting {
                // Compact icon buttons; meaning lives in the tooltips.
                let allSelected = !filtered.isEmpty && selected.count == filtered.count
                Button { selected = Set(filtered.map { $0.url }) } label: {
                    Image(systemName: "checklist.checked")
                }
                .disabled(allSelected)
                .help("Select all \(filtered.count)")

                Button { selected = [] } label: { Image(systemName: "xmark.circle") }
                    .disabled(selected.isEmpty)
                    .help("Clear selection")

                Button { copySelected() } label: { Image(systemName: "doc.on.doc") }
                    .disabled(selected.isEmpty)
                    .help("Copy \(selected.count) dictation\(selected.count == 1 ? "" : "s") to the clipboard")

                Button(role: .destructive) { pendingBulk = .selected } label: { Image(systemName: "trash") }
                    .disabled(selected.isEmpty)
                    .help("Move \(selected.count) selected to the Trash")

                Button(role: .destructive) { pendingBulk = .all } label: { Image(systemName: "trash.fill") }
                    .disabled(filtered.isEmpty)
                    .help("Move all \(filtered.count) listed to the Trash")

                Button("Done") { selecting = false; selected = [] }
                    .help("Exit selection mode")
            } else {
                if !apps.isEmpty {
                    Menu {
                        Button("All apps") { appFilter = "" }
                        Divider()
                        ForEach(apps, id: \.self) { app in
                            Button { appFilter = app } label: {
                                if appFilter == app { Label(app, systemImage: "checkmark") } else { Text(app) }
                            }
                        }
                    } label: {
                        Image(systemName: appFilter.isEmpty ? "line.3.horizontal.decrease.circle"
                                                             : "line.3.horizontal.decrease.circle.fill")
                    }
                    .help(appFilter.isEmpty ? "Filter by app" : "Filtered: \(appFilter)")
                }
                Button { newestFirst.toggle() } label: { Image(systemName: "arrow.up.arrow.down") }
                    .help(newestFirst ? "Sorted newest first" : "Sorted oldest first")

                Button { Task { await reload() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Rescan the archive — drops any dictations deleted on disk")
                    .disabled(loading)

                Button { selecting = true } label: { Image(systemName: "checklist") }
                    .help("Select multiple to copy or delete")
                    .disabled(items.isEmpty)
            }
        }
    }

    // Copy the concatenated text of the ticked items, in current list order.
    private func copySelected() {
        let joined = filtered.filter { selected.contains($0.url) }
            .map { $0.text }.joined(separator: "\n\n———\n\n")
        setClipboard(joined)
    }

    // MARK: Stats bar

    private var statsBar: some View {
        HStack(spacing: 16) {
            statChip("waveform", "\(filtered.count)", filtered.count == 1 ? "dictation" : "dictations")
            statChip("clock", UsageStats.hoursMinutes(totalSeconds), "recorded")
            if totalWords > 0 { statChip("textformat.123", "\(totalWords)", "words") }
            Spacer()
            if loading { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
    }

    private func statChip(_ icon: String, _ value: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.caption2).foregroundColor(.secondary)
            Text(value).font(.callout.bold().monospacedDigit())
            Text(label).font(.caption).foregroundColor(.secondary)
        }
    }

    // MARK: List column

    @ViewBuilder private var listColumn: some View {
        if items.isEmpty {
            emptyState
        } else if filtered.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease.circle").font(.title).foregroundColor(.secondary)
                Text("No matches").foregroundColor(.secondary)
                if !query.isEmpty || !appFilter.isEmpty {
                    Button("Clear filters") { query = ""; appFilter = "" }.font(.caption)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // Native selection-driven list, mirroring the Catalog window's
            // sidebar-style browser (day sections, tinted row icons, badges).
            List(selection: $selectedID) {
                ForEach(groups, id: \.day) { group in
                    Section(DateDisplay.day(group.day)) {
                        ForEach(group.items) { item in
                            row(item).tag(item.url)
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private func row(_ item: DictationItem) -> some View {
        HStack(spacing: 10) {
            if selecting {
                Button { toggle(item.url) } label: {
                    Image(systemName: selected.contains(item.url) ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(selected.contains(item.url) ? .accentColor : .secondary)
                }
                .buttonStyle(.plain)
            }
            // Tinted icon tile — the visual motif the Catalog sidebar uses.
            Image(systemName: "waveform")
                .foregroundStyle(.white).frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.gradient))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.app.isEmpty ? "—" : item.app).font(.callout.weight(.medium)).lineLimit(1)
                    if !item.style.isEmpty {
                        Text(item.style)
                            .font(.caption2).foregroundColor(.secondary)
                            .pillBackground(.secondary, opacity: 0.15, hPad: 5, vPad: 1)
                    }
                    Spacer()
                    Text(item.time.prefix(5))    // HH:mm
                        .font(.caption2).foregroundColor(.secondary).monospacedDigit()
                }
                if !item.preview.isEmpty {
                    Text(item.preview).font(.caption).foregroundColor(.secondary).lineLimit(2)
                }
                HStack(spacing: 8) {
                    Label(item.durationText, systemImage: "clock").labelStyle(.titleAndIcon)
                    if item.words > 0 { Label("\(item.words)", systemImage: "textformat.123") }
                }
                .font(.caption2).foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 3)
    }

    // MARK: Detail pane

    @ViewBuilder private var detailPane: some View {
        if let item = selectedItem {
            VStack(alignment: .leading, spacing: 0) {
                // Header
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.app.isEmpty ? "Dictation" : item.app).font(.title3.bold())
                    HStack(spacing: 10) {
                        Label(item.fullTimestamp, systemImage: "calendar")
                        if !item.style.isEmpty { Label(item.style, systemImage: "textformat") }
                        Label(item.durationText, systemImage: "clock")
                        if item.words > 0 { Label("\(item.words) words", systemImage: "textformat.123") }
                    }
                    .font(.caption).foregroundColor(.secondary)
                }
                .padding(14)
                Divider()

                // Body
                ScrollView {
                    Text(item.text.isEmpty ? "This dictation has no text." : item.text)
                        .font(.body)
                        .foregroundColor(item.text.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                }

                Divider()
                // Action bar
                HStack(spacing: 10) {
                    Button {
                        setClipboard(item.text); flashCopied(item.url)
                    } label: {
                        Label(copiedID == item.url ? "Copied!" : "Copy",
                              systemImage: copiedID == item.url ? "checkmark" : "doc.on.doc")
                    }
                    .disabled(item.text.isEmpty)
                    Button {
                        NotesViewerWindowController.present(fileURL: item.url)
                    } label: { Label("Open", systemImage: "arrow.up.forward.square") }
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([item.url])
                    } label: { Label("Reveal", systemImage: "folder") }
                    Spacer()
                    Button(role: .destructive) { pendingTrash = item } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .padding(12)
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "text.quote").font(.largeTitle).foregroundColor(.secondary)
                Text("Select a dictation").foregroundColor(.secondary)
                Text("Its full text and actions appear here.")
                    .font(.caption).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "waveform").font(.largeTitle).foregroundColor(.secondary)
            Text("No saved dictations yet.").foregroundColor(.secondary)
            Text("Enable “Save each dictation to a file” in Settings → Dictation.")
                .font(.caption).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Actions

    private func toggle(_ url: URL) {
        if selected.contains(url) { selected.remove(url) } else { selected.insert(url) }
    }

    private func setClipboard(_ text: String) { Clipboard.plain(text) }

    private func flashCopied(_ url: URL) {
        copiedID = url
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if copiedID == url { copiedID = nil }
        }
    }

    private func trash(_ item: DictationItem) {
        do {
            try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
            items.removeAll { $0.id == item.id }
            if selectedID == item.url { selectedID = nil }
        } catch {
            trashError = error.localizedDescription
        }
        pendingTrash = nil
    }

    /// Move the chosen dictations to the Trash. "All" respects the current
    /// filters (matching the toolbar count); "selected" uses the ticks.
    private func performBulk(_ kind: BulkKind) {
        let targets: [URL] = kind == .all ? filtered.map { $0.url } : Array(selected)
        var trashed = Set<URL>(), failed = 0
        for url in targets {
            do { try FileManager.default.trashItem(at: url, resultingItemURL: nil); trashed.insert(url) }
            catch { failed += 1 }
        }
        items.removeAll { trashed.contains($0.url) }
        selected.subtract(trashed)
        if let sel = selectedID, trashed.contains(sel) { selectedID = nil }
        pendingBulk = nil
        selecting = false
        if failed > 0 { trashError = "\(failed) file\(failed == 1 ? "" : "s") couldn't be moved to the Trash." }
    }

    /// Re-enumerate the archive off the main thread. `loadAll` only returns
    /// files that still exist, so deleted dictations disappear on reload.
    private func reload() async {
        loading = true
        let loaded = await Task.detached(priority: .userInitiated) { DictationItem.loadAll() }.value
        items = loaded
        // Keep the selection valid; default to the first item on first load.
        if let sel = selectedID, !loaded.contains(where: { $0.url == sel }) { selectedID = nil }
        loading = false
    }
}
