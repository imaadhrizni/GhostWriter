import SwiftUI
import AppKit

// MARK: - Dictations Browser
//
// A searchable, day-grouped list of archived dictations (the per-dictation
// Markdown files written when "Save each dictation to a file" is on). Kept
// separate from the meetings-only Catalog. Rows open in the shared
// in-app viewer/editor.

final class DictationsWindowController: NSWindowController {
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.center()
        window.title = "Dictations"
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
    let preview: String
    let seconds: Int

    /// Compact duration: "12s" under a minute, "1:23" above.
    var durationText: String {
        guard seconds > 0 else { return "" }
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

    /// Parse a dictation file: front-matter `app:`/`style:`/`duration:` and a body preview.
    init(url: URL) {
        self.url = url
        let content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        // Unwrap an optionally double-quoted YAML scalar.
        func unquote(_ s: String) -> String {
            var v = s.trimmingCharacters(in: .whitespaces)
            if v.hasPrefix("\""), v.hasSuffix("\""), v.count >= 2 {
                v = String(v.dropFirst().dropLast())
                    .replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\\\", with: "\\")
            }
            return v
        }

        let (frontMatter, bodyText) = FrontMatter.split(content)

        var app = "", style = "", secs = 0
        for line in (frontMatter ?? "").components(separatedBy: "\n") {
            if line.hasPrefix("app:") { app = unquote(String(line.dropFirst(4))) }
            if line.hasPrefix("style:") { style = unquote(String(line.dropFirst(6))) }
            if line.hasPrefix("duration:") {
                // stored as "duration: 12s"
                let v = String(line.dropFirst(9)).trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: "s", with: "")
                secs = Int(v) ?? 0
            }
        }
        let body = bodyText.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        self.app = app
        self.style = style
        self.preview = body.joined(separator: " ")
        self.seconds = secs
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

    private var filtered: [DictationItem] {
        guard !query.isEmpty else { return items }
        let q = query.lowercased()
        return items.filter {
            $0.preview.lowercased().contains(q) ||
            $0.app.lowercased().contains(q) ||
            $0.style.lowercased().contains(q)
        }
    }

    private var groups: [(day: String, items: [DictationItem])] {
        var result: [(day: String, items: [DictationItem])] = []
        for item in filtered {
            if result.last?.day == item.day { result[result.count - 1].items.append(item) }
            else { result.append((item.day, [item])) }
        }
        return result
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("Search dictations", text: $query)
                    .textFieldStyle(.roundedBorder)
                Button { Task { await reload() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Reload — drops any dictations deleted on disk")
                .disabled(loading)
            }
            .padding(.horizontal, 12).padding(.top, 12)

            if items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "waveform").font(.largeTitle).foregroundColor(.secondary)
                    Text("No saved dictations yet.").foregroundColor(.secondary)
                    Text("Enable “Save each dictation to a file” in Settings → Dictation.")
                        .font(.caption).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(groups, id: \.day) { group in
                        Section(header: Text(DateDisplay.day(group.day))) {
                            HStack {
                                Text("App").frame(maxWidth: .infinity, alignment: .leading)
                                Text("Style").frame(width: 110, alignment: .leading)
                                Text("Duration").frame(width: 64, alignment: .trailing)
                                Spacer().frame(width: 22)
                            }
                            .font(.caption2.bold()).foregroundColor(.secondary)
                            ForEach(group.items) { item in
                                Button {
                                    NotesViewerWindowController.present(fileURL: item.url)
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(item.app.isEmpty ? "—" : item.app).lineLimit(1)
                                            Text(item.time)
                                                .font(.caption2).foregroundColor(.secondary).monospacedDigit()
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        Text(item.style)
                                            .frame(width: 110, alignment: .leading)
                                            .foregroundColor(.secondary).lineLimit(1)
                                        Text(item.durationText)
                                            .frame(width: 64, alignment: .trailing)
                                            .monospacedDigit().foregroundColor(.secondary)
                                        Image(systemName: "arrow.up.forward.square")
                                            .foregroundColor(.secondary).frame(width: 22)
                                    }
                                    .font(.callout)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
        .frame(minWidth: 480, minHeight: 360)
        // Enumerating + parsing files is I/O — do it off the main thread so a
        // large archive doesn't freeze the window on open.
        .task { await reload() }
        // The window controller is cached and reused, so re-scan whenever it
        // becomes active again — a dictation deleted in Finder then drops off.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            Task { await reload() }
        }
    }

    /// Re-enumerate the archive off the main thread. `loadAll` only returns
    /// files that still exist, so deleted dictations disappear on reload.
    private func reload() async {
        loading = true
        items = await Task.detached(priority: .userInitiated) { DictationItem.loadAll() }.value
        loading = false
    }
}
