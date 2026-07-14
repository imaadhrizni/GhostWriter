import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Import Audio Window
//
// A dedicated window for turning existing audio files (e.g. voice notes from a
// chat app) into meeting notes: drop or browse for files, optionally assign an
// org/project, then transcribe with live per-file progress. Notes land in
// the Catalog for further triage (link / Move to Dictation / delete).

final class ImportAudioWindowController: NSWindowController {
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.center()
        window.title = "Transcribe Audio"
        self.init(window: window)
        window.contentView = NSHostingView(rootView: ImportAudioView())
    }
}

struct ImportAudioView: View {
    @ObservedObject private var service = AudioImportService.shared
    @ObservedObject private var catalog = CatalogStore.shared
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            dropZone

            if !service.items.isEmpty {
                fileList
                assignRow
            }

            Spacer(minLength: 0)
            footer
        }
        .padding(16)
        .frame(minWidth: 460, minHeight: 420)
    }

    // MARK: Drop zone / picker

    private var dropZone: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform.badge.plus").font(.system(size: 30)).foregroundStyle(.secondary)
            Text("Drag audio files here").font(.headline)
            Text("wav · mp3 · m4a · ogg / opus · flac · webm").font(.caption).foregroundStyle(.secondary)
            Button("Choose Files…", action: chooseFiles).padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(dropTargeted ? 0.15 : 0.06)))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.3),
                          style: StrokeStyle(lineWidth: 1.5, dash: [6])))
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { handleDrop($0) }
    }

    // MARK: File list

    private var fileList: some View {
        List {
            ForEach(service.items) { item in
                HStack(spacing: 8) {
                    statusIcon(item.status)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.name).lineLimit(1)
                        if let err = item.error {
                            Text(err).font(.caption2).foregroundStyle(.red).lineLimit(2)
                        }
                    }
                    Spacer()
                    if item.status == .done, let note = item.noteURL {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([note])
                        } label: { Image(systemName: "arrow.up.forward.square") }
                        .buttonStyle(.borderless).help("Reveal note in Finder")
                    }
                    if item.status == .queued {
                        Button { service.remove(item.id) } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary).help("Remove")
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .frame(minHeight: 140)
    }

    @ViewBuilder private func statusIcon(_ s: AudioImportService.Status) -> some View {
        switch s {
        case .queued:  Image(systemName: "clock").foregroundStyle(.secondary)
        case .working: ProgressView().controlSize(.small)
        case .done:    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:  Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    // MARK: Assignment

    @State private var showAssign = false

    private var assignRow: some View {
        HStack(spacing: 8) {
            Text("File under:").foregroundStyle(.secondary)
            Button {
                showAssign = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: service.targetKind.isEmpty ? "tray" : (service.targetKind == "project" ? "folder" : "building.2"))
                    Text(assignLabel)
                }
            }
            .popover(isPresented: $showAssign, arrowEdge: .bottom) {
                ImportAssignPopover(store: catalog, show: $showAssign,
                                    targetKind: $service.targetKind, targetID: $service.targetID)
            }
            .disabled(service.isRunning)
            if !service.targetKind.isEmpty {
                Button { service.targetKind = ""; service.targetID = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain).help("Clear")
            }
            Spacer()
        }
    }

    private var assignLabel: String {
        if service.targetKind == "project", let o = catalog.project(service.targetID) { return o.name }
        if service.targetKind == "org", let o = catalog.org(service.targetID) { return o.name }
        return "Unassigned"
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if service.items.contains(where: { $0.status == .done }) {
                Button("Clear finished") { service.clearFinished() }.disabled(service.isRunning)
            }
            Spacer()
            if service.isRunning { ProgressView().controlSize(.small).padding(.trailing, 4) }
            Button(service.isRunning ? "Transcribing…" : "Transcribe \(service.queuedCount) file\(service.queuedCount == 1 ? "" : "s")") {
                Task { await service.run() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(service.isRunning || service.queuedCount == 0)
        }
    }

    // MARK: Actions

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .mpeg4Audio, .mp3, .wav, .aiff]
        if panel.runModal() == .OK { service.add(panel.urls) }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return false }
        var urls: [URL] = []
        let group = DispatchGroup()
        for p in fileProviders {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                DispatchQueue.main.async {
                    if let url, AudioFileImporter.isAccepted(url) { urls.append(url) }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) { if !urls.isEmpty { service.add(urls) } }
        return true
    }
}

// MARK: - Import assignment picker

/// Searchable, hierarchical project/org picker for the import window — the
/// same shape as the Catalog note editor's "Filed under", but it reports the
/// choice back through bindings instead of mutating a note (the note rows don't
/// exist yet at import time).
private struct ImportAssignPopover: View {
    @ObservedObject var store: CatalogStore
    @Binding var show: Bool
    @Binding var targetKind: String
    @Binding var targetID: String
    @State private var mode = 0   // 0 = project, 1 = organisation
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $mode) {
                Text("Project").tag(0)
                Text("Organization").tag(1)
            }
            .pickerStyle(.segmented).labelsHidden()

            EntitySearchBar(text: $query, placeholder: mode == 0 ? "Search projects" : "Search organizations")

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    Button { choose("", "") } label: {
                        Label("Unassigned", systemImage: "tray").frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain).padding(.vertical, 3)
                    Divider()
                    if mode == 0 {
                        ForEach(filteredOpps) { o in
                            row(o.name, subtitle: store.projectPath(of: o.id)) { choose("project", o.id) }
                        }
                    } else {
                        ForEach(filteredOrgs) { o in
                            row(o.name, subtitle: store.orgPath(of: o.id)) { choose("org", o.id) }
                        }
                    }
                }
            }
            .frame(height: 220)
        }
        .padding(10)
        .frame(width: 300)
    }

    private func row(_ name: String, subtitle: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 1) {
                Text(name).lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain).padding(.vertical, 3)
    }

    private func choose(_ kind: String, _ id: String) {
        targetKind = kind; targetID = id; show = false
    }

    private var filteredOpps: [CatalogProject] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let all = store.projectsSorted
        return q.isEmpty ? all : all.filter { $0.name.lowercased().contains(q) }
    }
    private var filteredOrgs: [CatalogOrg] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? store.orgsSorted : store.orgsSorted.filter { $0.name.lowercased().contains(q) }
    }
}
