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
    @State private var tab: Tab = .transcribe
    /// Past transcriptions, derived from the Catalog (notes marked
    /// `gw_source: import`) rather than a parallel store — so it survives relaunch
    /// and never drifts. Cached here; refreshed on appear and after each run.
    @State private var history: [CatalogNote] = []
    @State private var historyQuery = ""
    @State private var pendingTrash: CatalogNote?
    @State private var trashError: String?
    @State private var showClearAll = false
    /// Import-origin notes recoverable via Rebuild (computed when History is
    /// empty, so the empty state can offer recovery after a Clear All).
    @State private var recoverableCount = 0

    /// The window's two surfaces: doing the work vs. looking back at it.
    private enum Tab: Hashable { case transcribe, history }

    /// The active work surface only — queued, in-flight, and failed files.
    /// Finished files leave the queue and reappear under Transcribe History.
    private var queueItems: [AudioImportService.Item] {
        service.items.filter { $0.status != .done }
    }

    /// History filtered by the tab's search field (case-insensitive title match).
    private var filteredHistory: [CatalogNote] {
        let q = historyQuery.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return history }
        return history.filter { $0.title.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(spacing: 12) {
            Picker("", selection: $tab) {
                Text("Transcribe").tag(Tab.transcribe)
                Text(history.isEmpty ? "History" : "History (\(history.count))").tag(Tab.history)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch tab {
            case .transcribe: transcribeTab
            case .history:    historyTab
            }
        }
        .padding(16)
        .frame(minWidth: 460, minHeight: 440)
        .task { refreshHistory() }
        // Refresh when a run finishes (rather than on every per-file status tick)
        // so newly-transcribed notes drop into history. Explicit actions
        // (clear / regenerate) refresh directly.
        .onChange(of: service.isRunning) { _, running in if !running { refreshHistory() } }
        .confirmationDialog(
            "Move this transcription to Trash?",
            isPresented: Binding(get: { pendingTrash != nil }, set: { if !$0 { pendingTrash = nil } }),
            presenting: pendingTrash
        ) { note in
            Button("Move to Trash", role: .destructive) {
                do { _ = try CatalogStore.shared.trashNote(note.id) }
                catch { trashError = error.localizedDescription }
                refreshHistory()
            }
            Button("Cancel", role: .cancel) {}
        } message: { note in
            Text("“\(note.title)” — the Markdown note is sent to the macOS Trash (recoverable) and removed from the Catalog. The original audio file is not touched.")
        }
        .alert("Couldn't move to Trash", isPresented: Binding(get: { trashError != nil }, set: { if !$0 { trashError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(trashError ?? "") }
        .confirmationDialog("Clear all Transcribe History?", isPresented: $showClearAll, titleVisibility: .visible) {
            Button("Clear All", role: .destructive) { clearAllHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Empties the History list (\(history.count) items). The notes stay in the Catalog and can be restored by re-selecting the same audio; nothing is deleted.")
        }
    }

    // MARK: Transcribe tab

    private var transcribeTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let summary = service.lastRun { completionBanner(summary) }

            dropZone

            if !queueItems.isEmpty {
                fileList
                assignRow
            }

            Spacer(minLength: 0)
            footer
        }
    }

    /// A dismissible outcome banner shown after a run so success isn't silent —
    /// the queue empties on completion, and this is the window's confirmation.
    @ViewBuilder private func completionBanner(_ s: AudioImportService.RunSummary) -> some View {
        let ok = s.failed == 0
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? .green : .orange)
            Text(bannerText(s)).font(.callout)
            Spacer()
            if s.done > 0 {
                Button("View in History") { tab = .history; service.lastRun = nil }
                    .buttonStyle(.borderless)
            }
            Button { service.lastRun = nil } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless).foregroundStyle(.secondary).help("Dismiss")
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill((ok ? Color.green : Color.orange).opacity(0.12)))
    }

    private func bannerText(_ s: AudioImportService.RunSummary) -> String {
        func files(_ n: Int) -> String { "\(n) file\(n == 1 ? "" : "s")" }
        switch (s.done, s.failed) {
        case (let d, 0):            return "Transcribed \(files(d))"
        case (0, let f):            return "Couldn't transcribe \(files(f))"
        case (let d, let f):        return "Transcribed \(files(d)) · \(f) failed"
        }
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
            ForEach(queueItems) { item in
                HStack(spacing: 8) {
                    if item.duplicate {
                        Image(systemName: "doc.on.doc").foregroundStyle(.secondary)
                    } else {
                        statusIcon(item.status)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.name).lineLimit(1)
                        if item.duplicate {
                            Text("Already transcribed").font(.caption2).foregroundStyle(.secondary)
                        } else if let err = item.error {
                            Text(err).font(.caption2).foregroundStyle(.red).lineLimit(2)
                        }
                    }
                    Spacer()
                    if item.duplicate {
                        Menu {
                            if item.duplicateInHistory {
                                Button { showInHistory(item) } label: {
                                    Label("Show in History", systemImage: "clock.arrow.circlepath")
                                }
                            } else if item.duplicateNoteID != nil {
                                Button { addToHistory(item) } label: {
                                    Label("Add to History", systemImage: "tray.and.arrow.down")
                                }
                            }
                            Button { service.transcribeAnyway(item.id) } label: {
                                Label("Transcribe Anyway", systemImage: "arrow.clockwise")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .buttonStyle(.borderless).menuIndicator(.hidden).fixedSize()
                        .disabled(service.isRunning)
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

    // MARK: History tab

    /// Past transcriptions, derived from the Catalog. A quick lookback log — the
    /// notes' real home is the Catalog (reachable via each row's Reveal action);
    /// a row's Clear only hides it here (drops the `gw_source` marker), never
    /// deletes the underlying Markdown note or any audio.
    @ViewBuilder private var historyTab: some View {
        if history.isEmpty {
            if recoverableCount > 0 {
                // History was cleared but the notes remain — offer to rebuild.
                ContentUnavailableView {
                    Label("History is empty", systemImage: "clock.arrow.circlepath")
                } description: {
                    Text("\(recoverableCount) transcribed note\(recoverableCount == 1 ? "" : "s") can be brought back.")
                } actions: {
                    Button("Rebuild from Notes") { rebuildHistory() }
                }
            } else {
                ContentUnavailableView("No transcriptions yet", systemImage: "clock.arrow.circlepath",
                                       description: Text("Files you transcribe on the Transcribe tab show up here."))
            }
        } else {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    EntitySearchBar(text: $historyQuery, placeholder: "Filter by title")
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([AppSettings.shared.notesFolder])
                    } label: { Image(systemName: "folder") }
                    .buttonStyle(.borderless).help("Reveal notes folder in Finder")
                    Menu {
                        Button { refreshHistory() } label: { Label("Reload", systemImage: "arrow.clockwise") }
                        Button { rebuildHistory() } label: { Label("Rebuild from Notes", systemImage: "arrow.triangle.2.circlepath") }
                        Divider()
                        Button(role: .destructive) { showClearAll = true } label: {
                            Label("Clear All from History", systemImage: "xmark.circle")
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .buttonStyle(.borderless).menuIndicator(.hidden).fixedSize()
                }
                List {
                    ForEach(filteredHistory) { note in
                        HStack(spacing: 8) {
                            Image(systemName: "doc.text").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(note.title).lineLimit(1)
                                if let d = note.date {
                                    Text(d.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Menu {
                                noteActions(note)
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                            .buttonStyle(.borderless).menuIndicator(.hidden).fixedSize()
                        }
                        .padding(.vertical, 2)
                        .contextMenu { noteActions(note) }
                    }
                }
                .overlay {
                    if filteredHistory.isEmpty {
                        ContentUnavailableView.search(text: historyQuery)
                    }
                }
            }
        }
    }

    /// The shared per-note action set — used by both the history row's ⋯ menu and
    /// its right-click context menu, so the two never drift.
    @ViewBuilder private func noteActions(_ note: CatalogNote) -> some View {
        Button { openNote(note) } label: { Label("Open in Viewer", systemImage: "doc.text") }
        Button { revealInCatalog(note) } label: { Label("Reveal in Catalog", systemImage: "tray.full") }
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([catalog.url(of: note)])
        } label: { Label("Reveal in Finder", systemImage: "folder") }
        Button { copyTranscript(note) } label: { Label("Copy Transcript", systemImage: "doc.on.doc") }
        if let audio = catalog.audioURL(of: note) {
            Divider()
            Button {
                Task { _ = await service.regenerate(fromAudio: audio, like: note); refreshHistory() }
            } label: { Label("Regenerate from Audio", systemImage: "arrow.clockwise") }
            .disabled(service.isRunning)
        }
        Divider()
        Button {
            clearHistoryMarker(note); refreshHistory()
        } label: { Label("Clear from History", systemImage: "xmark.circle") }
        Button(role: .destructive) { pendingTrash = note } label: {
            Label("Move to Trash…", systemImage: "trash")
        }
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

    /// Rebuild the history list from the Catalog's imported-audio notes. When it
    /// comes up empty, also count import-origin notes so the empty state can offer
    /// to recover them (cheap in the common non-empty case — no extra scan).
    private func refreshHistory() {
        history = catalog.importedAudioNotes()
        recoverableCount = history.isEmpty ? catalog.importOriginNotes().count : history.count
    }

    /// Front the Catalog and select this note there (handled app-side).
    private func revealInCatalog(_ note: CatalogNote) {
        NotificationCenter.default.post(name: .revealNoteInCatalog, object: note.id)
    }

    /// Copy the note's transcript body (front-matter stripped) to the clipboard.
    private func copyTranscript(_ note: CatalogNote) {
        guard let text = catalog.url(of: note).readText() else { return }
        Clipboard.plain(FrontMatter.body(text).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Remove this note from Transcribe History without touching the note itself:
    /// clear its `gw_source: import` marker so the Catalog-derived history no
    /// longer lists it. The Markdown note and any audio stay exactly as they are.
    private func clearHistoryMarker(_ note: CatalogNote) {
        FrontMatter.mutate(fileURL: catalog.url(of: note)) { lines in
            lines.removeAll { $0.trimmingCharacters(in: .whitespaces).hasPrefix("gw_source:") }
        }
    }

    /// Empty the whole History list — bulk `clearHistoryMarker` over every listed
    /// note. Notes remain in the Catalog; each can be restored by re-selecting its
    /// audio ("Add to History") or all at once via "Rebuild from Notes", since the
    /// permanent `gw_source_file` marker is left intact.
    private func clearAllHistory() {
        for note in history { clearHistoryMarker(note) }
        refreshHistory()
    }

    /// Rebuild the full History by scanning every import-origin note (permanent
    /// `gw_source_file` marker) and re-stamping the `gw_source: import` marker —
    /// recovering rows that were cleared, which plain Reload can't. No
    /// re-transcription; purely a marker rewrite.
    private func rebuildHistory() {
        for note in catalog.importOriginNotes() { setImportMarker(on: note) }
        refreshHistory()
    }

    /// Re-stamp the `gw_source: import` marker on a note (adding it if absent),
    /// putting it back in History without touching anything else.
    private func setImportMarker(on note: CatalogNote) {
        FrontMatter.mutate(fileURL: catalog.url(of: note)) { lines in
            if !FrontMatter.replaceLine(prefix: "gw_source:", with: "gw_source: import", in: &lines) {
                lines.append("gw_source: import")
            }
        }
    }

    /// Restore a previously-cleared import to History: re-stamp its marker (no
    /// re-transcription, no cost), drop the queue item, and jump to the History
    /// tab so the restored row is visible.
    private func addToHistory(_ item: AudioImportService.Item) {
        guard let id = item.duplicateNoteID, let note = catalog.note(id: id) else { return }
        setImportMarker(on: note)
        service.remove(item.id)
        refreshHistory()
        tab = .history
    }

    /// The matched import is already in History — just surface it: drop the
    /// redundant queue item and switch to the History tab.
    private func showInHistory(_ item: AudioImportService.Item) {
        service.remove(item.id)
        tab = .history
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

