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
                    if item.status == .failed {
                        Button { service.retry(item.id) } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.borderless).help("Retry")
                            .disabled(service.isRunning)
                    }
                    if item.status == .queued || item.status == .failed {
                        Button { service.remove(item.id) } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary).help("Remove")
                            .disabled(service.isRunning)
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

    private var assignRow: some View {
        HStack(spacing: 8) {
            Text("File under:").foregroundStyle(.secondary)
            OrgProjectTreePicker(store: catalog, kind: $service.targetKind, id: $service.targetID,
                                 allLabel: "Unassigned")
                .disabled(service.isRunning)
            Spacer()
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if service.items.contains(where: { $0.status == .done }) {
                Button("Clear finished") { service.clearFinished() }.disabled(service.isRunning)
            }
            if service.failedCount > 0 {
                Button("Retry failed") { service.retryFailed() }.disabled(service.isRunning)
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

