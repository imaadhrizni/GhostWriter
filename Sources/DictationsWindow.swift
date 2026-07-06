import SwiftUI
import AppKit

// MARK: - Dictations Browser
//
// A searchable, day-grouped list of archived dictations (the per-dictation
// Markdown files written when "Save each dictation to a file" is on). Kept
// separate from the meetings-only Notes Assistant. Rows open in the shared
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

    func showAndActivate() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Model

private struct DictationItem: Identifiable, Hashable {
    let url: URL
    var id: URL { url }
    let app: String
    let style: String
    let preview: String

    private var stamp: String {
        url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "Dictation_", with: "")   // yyyy-MM-dd_HH-mm-ss
    }
    var day: String { String(stamp.prefix(10)) }
    var time: String {
        stamp.count > 11 ? String(stamp.dropFirst(11)).replacingOccurrences(of: "-", with: ":") : stamp
    }

    /// Parse a dictation file: front-matter `app:`/`style:` and a body preview.
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

        var app = "", style = "", body: [String] = []
        var inFrontMatter = false
        for (i, line) in content.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if i == 0, line == "---" { inFrontMatter = true; continue }
            if inFrontMatter {
                if line == "---" { inFrontMatter = false; continue }
                if line.hasPrefix("app:") { app = unquote(String(line.dropFirst(4))) }
                if line.hasPrefix("style:") { style = unquote(String(line.dropFirst(6))) }
            } else {
                // Everything outside the front-matter block is body content —
                // works whether or not the file has front-matter.
                let t = line.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { body.append(t) }
            }
        }
        self.app = app
        self.style = style
        self.preview = body.joined(separator: " ")
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
                            ForEach(group.items) { item in
                                Button {
                                    NotesViewerWindowController.present(fileURL: item.url)
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack {
                                            Text(item.time).monospacedDigit()
                                            if !item.app.isEmpty {
                                                Text("· \(item.app)").foregroundColor(.secondary)
                                            }
                                            if !item.style.isEmpty {
                                                Text("· \(item.style)").foregroundColor(.secondary)
                                            }
                                            Spacer()
                                            Image(systemName: "arrow.up.forward.square").foregroundColor(.secondary)
                                        }
                                        .font(.caption)
                                        if !item.preview.isEmpty {
                                            Text(item.preview).lineLimit(2).font(.callout)
                                        }
                                    }
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
        .task { items = await Task.detached(priority: .userInitiated) { DictationItem.loadAll() }.value }
    }
}
