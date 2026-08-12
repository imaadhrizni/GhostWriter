import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Catalog · Notes list, Ask, note editor & chips

struct NotesList: View {
    @ObservedObject var store: CatalogStore
    @Binding var selID: String?
    /// A note id to reveal (select + expand its date group + scroll into view),
    /// set by the Catalog when handling `.selectCatalogNote`. Cleared here once
    /// handled. `nil` in every caller that doesn't drive reveal.
    @Binding var reveal: String?
    let query: String
    let scope: NoteSearchScope
    let fOrg: String, fProject: String, fTag: String, fPerson: String
    var unassignedOnly: Bool = false
    var missingOnly: Bool = false
    var range: DateRange = .all
    @State private var semanticOrder: [String] = []
    @State private var hovered: String?
    @State private var pendingTrash: CatalogNote?
    @State private var pendingDictation: CatalogNote?
    @State private var trashError: String?
    @State private var dropTargeted = false
    // Which Year/Month/Day groups are open (browse mode only).
    @State private var expanded: Set<String> = []
    // Bulk multi-select.
    @State private var selecting = false
    @State private var multiSel = Set<String>()
    @State private var pendingBulkTrash = false
    @State private var showBulkAssign = false

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }

    /// A live search collapses the date grouping to a flat, rank-ordered list;
    /// browsing (no query) shows the collapsible Year → Month → Day tree.
    private var searching: Bool { !trimmedQuery.isEmpty }

    private func facetFiltered(_ notes: [CatalogNote]) -> [CatalogNote] {
        var ns = notes
        if !fOrg.isEmpty { ns = ns.filter { store.effectiveOrgIDs(of: $0).contains(fOrg) } }
        if !fProject.isEmpty { ns = ns.filter { store.effectiveProjectIDs(of: $0).contains(fProject) } }
        if !fTag.isEmpty { ns = ns.filter { $0.tagIDs.contains(fTag) } }
        if !fPerson.isEmpty { ns = ns.filter { $0.personIDs.contains(fPerson) } }
        if unassignedOnly { ns = ns.filter(store.isUnassigned) }
        if missingOnly { ns = ns.filter { !store.fileExists($0) } }
        // Time window (undated notes drop out while a window is active).
        ns = ns.filter { range.includes($0.date) }
        return ns
    }

    private var filtered: [CatalogNote] {
        if scope == .meaning && searching {
            let rank = Dictionary(uniqueKeysWithValues: semanticOrder.enumerated().map { ($0.element, $0.offset) })
            let base = store.doc.notes.filter { rank[$0.id] != nil }
                .sorted { (rank[$0.id] ?? 0) < (rank[$1.id] ?? 0) }
            return facetFiltered(base)
        }
        var ns = store.doc.notes
        if searching { ns = ns.filter { store.noteMatches($0, query: trimmedQuery) } }
        return facetFiltered(ns).sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    private var groups: [DateGroupNode<CatalogNote>] {
        DateGrouping.tree(filtered) { $0.date }
    }

    /// Select, expand, and scroll a revealed note into view, then clear the
    /// `reveal` binding so the same id can be revealed again later. No-op when
    /// `id` is nil or names a note that isn't in the store.
    private func performReveal(_ id: String?, proxy: ScrollViewProxy) {
        guard let id, let target = store.note(id: id) else { return }
        selID = id
        expanded.formUnion(Self.dateGroupKeys(for: target.date))
        DispatchQueue.main.async {
            withAnimation { proxy.scrollTo(id, anchor: .center) }
            reveal = nil
        }
    }

    /// The year / month / day expansion keys for a note's date, matching the
    /// local-calendar keys `DateGrouping.tree` assigns, so revealing a note can
    /// open exactly the groups that contain it. `nil` dates live under "0000".
    private static func dateGroupKeys(for date: Date?) -> Set<String> {
        guard let date else { return ["0000"] }
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        let day = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        return [String(day.prefix(4)), String(day.prefix(7)), day]
    }

    var body: some View {
        Group {
            if store.doc.notes.isEmpty {
                ContentUnavailableView {
                    Label("No notes yet", systemImage: "doc.text")
                } description: {
                    Text("Use “Import notes” to add meeting notes.")
                }
            } else {
                VStack(spacing: 0) {
                    HStack {
                        Button {
                            selecting.toggle(); multiSel.removeAll()
                        } label: {
                            Label("Select", systemImage: selecting ? "checkmark.circle.fill" : "checkmark.circle")
                        }
                        .buttonStyle(.borderless).font(.caption)
                        .help("Select multiple to assign or delete")
                        Spacer()
                        if !searching && !filtered.isEmpty {
                            ExpandCollapseButton(tree: groups, expanded: $expanded)
                                .buttonStyle(.borderless).font(.caption)
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    ScrollViewReader { proxy in
                        Group {
                            if selecting {
                                List(selection: $multiSel) { noteListContent }
                            } else {
                                List(selection: $selID) { noteListContent }
                            }
                        }
                        // "Reveal in Catalog": select the note, expand the date
                        // group holding it (so a browse-mode row isn't hidden in a
                        // collapsed group), and scroll it into view. Driven by the
                        // `reveal` binding — handled both when the list is already
                        // mounted (onChange) and when it mounts with a pending
                        // reveal (onAppear) — then cleared.
                        .onChange(of: reveal) { _, id in performReveal(id, proxy: proxy) }
                        .onAppear { performReveal(reveal, proxy: proxy) }
                    }
                    if selecting { bulkBar }
                }
                .overlay { if filtered.isEmpty { ContentUnavailableView.search } }
                // Seed the open groups (newest year/month) once results arrive.
                .onChange(of: groups.map(\.id)) { _, _ in
                    if expanded.isEmpty { expanded = DateGrouping.defaultExpanded(groups) }
                }
                .onAppear { if expanded.isEmpty { expanded = DateGrouping.defaultExpanded(groups) } }
            }
        }
        .task(id: "\(scope)|\(trimmedQuery)") { await runSemantic() }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in handleDrop(providers) }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .background(Color.accentColor.opacity(0.06))
                    .overlay(Label("Drop audio to transcribe", systemImage: "waveform.badge.plus")
                        .font(.headline).foregroundStyle(.secondary))
                    .allowsHitTesting(false)
            }
        }
        .confirmationDialog(
            "Move this note to Dictation?",
            isPresented: Binding(get: { pendingDictation != nil }, set: { if !$0 { pendingDictation = nil } }),
            presenting: pendingDictation
        ) { n in
            Button("Move to Dictation") {
                if selID == n.id { selID = nil }
                do {
                    try store.moveNoteToDictation(n.id)
                } catch {
                    trashError = error.localizedDescription
                }
                pendingDictation = nil
            }
            Button("Cancel", role: .cancel) { pendingDictation = nil }
        } message: { n in
            Text("“\(n.title)” will be saved to the dictation archive and removed from the Catalog. Its meeting summary (if any) is not carried over.")
        }
        .confirmationDialog(
            "Move this note to the Trash?",
            isPresented: Binding(get: { pendingTrash != nil }, set: { if !$0 { pendingTrash = nil } }),
            presenting: pendingTrash
        ) { n in
            let audio = store.audioURL(of: n)
            Button(audio == nil ? "Move to Trash" : "Move Note Only", role: .destructive) {
                trashNote(n, alsoAudio: false)
            }
            if audio != nil {
                Button("Move Note & Recording to Trash", role: .destructive) {
                    trashNote(n, alsoAudio: true)
                }
            }
            Button("Cancel", role: .cancel) { pendingTrash = nil }
        } message: { n in
            let hasAudio = store.audioURL(of: n) != nil
            Text("“\(n.title)” will be moved to the Trash and removed from the Catalog."
                 + (hasAudio ? " It also has a saved recording — choose whether to trash that too." : "")
                 + " You can recover items from the Trash.")
        }
        .alert("Couldn't delete the note", isPresented: Binding(get: { trashError != nil }, set: { if !$0 { trashError = nil } })) {
            Button("OK", role: .cancel) { trashError = nil }
        } message: {
            Text(trashError ?? "")
        }
        .confirmationDialog(
            "Move \(multiSel.count) note\(multiSel.count == 1 ? "" : "s") to the Trash?",
            isPresented: $pendingBulkTrash
        ) {
            let withAudio = selectedRecordings()
            Button(withAudio.isEmpty ? "Move to Trash" : "Move Notes Only", role: .destructive) {
                trashSelected(alsoAudio: false)
            }
            if !withAudio.isEmpty {
                Button("Move Notes & \(withAudio.count) Recording\(withAudio.count == 1 ? "" : "s") to Trash", role: .destructive) {
                    trashSelected(alsoAudio: true)
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            let n = selectedRecordings().count
            Text("The Markdown files move to the Trash and their Catalog rows are removed."
                 + (n > 0 ? " \(n) of the selected notes have a saved recording — choose whether to trash those too." : "")
                 + " You can recover items from the Trash.")
        }
        .sheet(isPresented: $showBulkAssign) {
            BulkAssignSheet(store: store, noteIDs: Array(multiSel))
        }
    }

    /// Trash one note, optionally also moving its retained recording to Trash.
    private func trashNote(_ n: CatalogNote, alsoAudio: Bool) {
        if selID == n.id { selID = nil }
        let audio = alsoAudio ? store.audioURL(of: n) : nil
        do { try store.trashNote(n.id) } catch { trashError = error.localizedDescription }
        if let audio { try? FileManager.default.trashItem(at: audio, resultingItemURL: nil) }
        pendingTrash = nil
    }

    /// Selected notes that have a retained recording on disk.
    private func selectedRecordings() -> [URL] {
        multiSel.compactMap { id in store.note(id: id).flatMap { store.audioURL(of: $0) } }
    }

    /// Trash the selected notes, optionally also their recordings.
    private func trashSelected(alsoAudio: Bool) {
        let ids = Array(multiSel)
        let audios = alsoAudio ? selectedRecordings() : []
        if let sel = selID, multiSel.contains(sel) { selID = nil }
        _ = store.trashNotes(ids)
        for url in audios { try? FileManager.default.trashItem(at: url, resultingItemURL: nil) }
        multiSel.removeAll()
    }

    /// The list rows, shared by the single- and multi-select list variants.
    @ViewBuilder private var noteListContent: some View {
        if searching {
            ForEach(filtered) { noteRow($0) }
        } else {
            DateGroupDisclosure(nodes: groups, expanded: $expanded) { noteRow($0) }
        }
    }

    /// Bulk action bar shown while selecting multiple notes.
    private var bulkBar: some View {
        let ids = Array(multiSel)
        return VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                Text(ids.isEmpty ? "Select notes" : "\(ids.count) selected")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button { showBulkAssign = true } label: { Label("Assign…", systemImage: "tag") }
                    .disabled(ids.isEmpty)
                Button(role: .destructive) { pendingBulkTrash = true } label: {
                    Label("Trash", systemImage: "trash")
                }.disabled(ids.isEmpty)
                Button("Done") { selecting = false; multiSel.removeAll() }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .background(.bar)
    }


    /// A single note row — title, badges, date/tags, and hover/context actions.
    /// Tagged with the note id so it participates in the List's selection whether
    /// it sits in a flat search result or nested inside a date group.
    @ViewBuilder private func noteRow(_ n: CatalogNote) -> some View {
        let missing = !store.fileExists(n)
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(n.title).lineLimit(1).foregroundStyle(missing ? .secondary : .primary)
                    if missing {
                        CapsulePill(text: "File missing", color: .red)
                    } else if store.isUnassigned(n) {
                        CapsulePill(text: "Unassigned", color: .orange)
                    }
                }
                HStack(spacing: 6) {
                    if let d = n.date { Text(d.formatted(date: .abbreviated, time: .shortened)) }
                    if !n.tagIDs.isEmpty { Text("· \(n.tagIDs.count) tags") }
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            // Row actions — always shown for missing rows (they need triage),
            // otherwise revealed on hover to keep it clean.
            if hovered == n.id || missing {
                if !missing {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([store.url(of: n)])
                    } label: { Image(systemName: "folder") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .help("Reveal in Finder")
                }
                if missing {
                    // File is already gone — the only action is to drop the stale row.
                    Button {
                        if selID == n.id { selID = nil }
                        store.deleteNote(n.id)
                    } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).foregroundStyle(.red)
                    .help("Remove this missing entry from the catalog")
                } else {
                    Menu {
                        Button("Remove from Catalog (keep file)") {
                            if selID == n.id { selID = nil }
                            store.deleteNote(n.id)
                        }
                        Button("Move Note to Trash…", role: .destructive) {
                            pendingTrash = n
                        }
                    } label: { Image(systemName: "trash") }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .foregroundStyle(.secondary)
                    .help("Remove from catalog, or move the note file to Trash")
                }
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onHover { hovered = $0 ? n.id : (hovered == n.id ? nil : hovered) }
        .contextMenu {
            if !missing {
                Button("Open") { selID = n.id }
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([store.url(of: n)])
                }
                Divider()
                Button("Move to Dictation…") { pendingDictation = n }
            }
            Button("Remove from Catalog") {
                if selID == n.id { selID = nil }
                store.deleteNote(n.id)
            }
            if !missing {
                Button("Move to Trash…", role: .destructive) { pendingTrash = n }
            }
        }
        .tag(n.id)
    }


    /// Accept dropped audio files → hand them to the importer, which transcribes
    /// each into a meeting note and adds a Catalog row. Non-audio drops are
    /// ignored (returns false so the system shows the "no" cursor).
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
        group.notify(queue: .main) {
            guard !urls.isEmpty else { return }
            (NSApp.delegate as? AppDelegate)?.showAudioImport(urls: urls)
        }
        return true
    }

    private func runSemantic() async {
        guard scope == .meaning, !trimmedQuery.isEmpty else { semanticOrder = []; return }
        let hits = await NotesLibrary.semanticSearch(trimmedQuery)
        let byPath = Dictionary(store.doc.notes.map { (store.url(of: $0).path, $0.id) }, uniquingKeysWith: { a, _ in a })
        semanticOrder = hits.compactMap { byPath[$0.file.url.path] }
    }
}

enum NoteSearchScope: Hashable { case text, meaning, ask }

/// Filter-scoped Ask: retrieves excerpts from the currently-filtered notes,
/// answers with the polishing model, and cites the source notes.
struct NoteAskView: View {
    @ObservedObject var store: CatalogStore
    let question: String
    let nonce: Int
    let files: [NotesLibrary.MeetingFile]
    let filterSummary: String
    var onPickNote: (String) -> Void

    @State private var answer = ""
    @State private var sources: [NotesLibrary.MeetingFile] = []
    @State private var isAsking = false
    @State private var errorMessage: String?
    private let polisher = TextPolisher()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Label("Asking across: \(filterSummary)", systemImage: "line.3.horizontal.decrease.circle")
                    .font(.caption).foregroundStyle(.secondary)

                if isAsking {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Thinking…").foregroundStyle(.secondary) }
                } else if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                } else if !answer.isEmpty {
                    Text(question).font(.headline)
                    Text(answer).textSelection(.enabled)
                    if !sources.isEmpty {
                        Divider()
                        Text("Sources").font(.caption).foregroundStyle(.secondary)
                        ForEach(sources) { f in
                            if let note = store.doc.notes.first(where: { store.url(of: $0).path == f.url.path }) {
                                Button { onPickNote(note.id) } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: "doc.text").foregroundStyle(.secondary)
                                        Text(note.title).lineLimit(1)
                                        Spacer()
                                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                                    }
                                }.buttonStyle(.plain)
                            } else {
                                Button { NotesViewerWindowController.present(fileURL: f.url) } label: {
                                    Label(f.displayName, systemImage: "doc.text")
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                } else {
                    ContentUnavailableView("Ask about these notes",
                        systemImage: "sparkles",
                        description: Text("Type a question in the search field and press Return. Answers are drawn only from the filtered notes, with cited sources."))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .task(id: nonce) { if nonce > 0 { await run() } }
    }

    private func run() async {
        let q = question.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        isAsking = true; errorMessage = nil; answer = ""; sources = []
        guard !files.isEmpty else {
            answer = "No notes match the current filters."; isAsking = false; return
        }
        do {
            let retrieved = NotesLibrary.semanticAvailable
                ? await NotesLibrary.semanticExcerpts(for: q, files: files)
                : fallbackExcerpts()
            if retrieved.text.isEmpty {
                answer = "Nothing in these notes matched the question. Try rewording or widening the filters."
            } else {
                answer = try await polisher.answerAcrossMeetings(question: q, excerpts: retrieved.text)
                sources = retrieved.sources
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isAsking = false
    }

    /// When no on-device embedding model exists, just feed the filtered notes'
    /// text (capped) so Ask still works — scoped to the same files.
    private func fallbackExcerpts() -> NotesLibrary.ExcerptResult {
        var out = "", used: [NotesLibrary.MeetingFile] = []
        for f in files {
            guard let body = f.url.readText() else { continue }
            let block = "\n=== Meeting \(f.displayName) ===\n\(body)\n"
            if out.count + block.count > 20_000 { break }
            out += block; used.append(f)
        }
        return NotesLibrary.ExcerptResult(text: out, sources: used)
    }
}

// MARK: Note editor — chip-based assignment

struct NoteLinkEditor: View {
    @ObservedObject var store: CatalogStore
    let note: CatalogNote
    @State private var showAssign = false
    @State private var titleDraft = ""
    @State private var meetingTypeID = ""
    @State private var audioRelPath = ""
    @State private var audioBusy = false
    @State private var audioStatus = ""

    private var current: CatalogNote { store.note(id: note.id) ?? note }
    private var fileURL: URL { store.url(of: note) }
    private var isMeetingNote: Bool { note.filePath.hasSuffix(".md") && FileManager.default.fileExists(atPath: fileURL.path) }

    /// Persist an edited note title to both the Catalog row and the file's
    /// front-matter, keeping the two in sync (as finalize does).
    private func commitTitle() {
        let t = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t != current.title else { return }
        store.renameNote(relativePath: note.filePath, to: t)
        MeetingNotesWriter.setFrontMatterTitle(t, to: fileURL)
    }

    /// Load the front-matter fields the editor edits directly (meeting type,
    /// retained-audio path) — empty when the note has none.
    private func loadMeetingType() {
        let text = fileURL.readText() ?? ""
        meetingTypeID = FrontMatter.field("gw_meeting_type", in: text) ?? ""
        audioRelPath = FrontMatter.field("gw_audio", in: text) ?? ""
    }

    private var audioURL: URL {
        AppSettings.shared.notesFolder.appendingPathComponent(audioRelPath)
    }

    /// Re-transcribe the retained recording into a fresh, fully-generated note
    /// (filed like this one) — the recovery path when the original failed.
    private func regenerateFromAudio() {
        audioBusy = true; audioStatus = "Re-transcribing from recording…"
        Task { @MainActor in
            defer { audioBusy = false }
            if let newURL = await AudioImportService.shared.regenerate(fromAudio: audioURL, like: current) {
                audioStatus = "New note created from the recording."
                NotesViewerWindowController.present(fileURL: newURL)
            } else {
                audioStatus = "Re-transcription failed."
            }
        }
    }

    /// Safely delete the recording (moves it to the Trash) and drop the link.
    private func deleteRecording() {
        store.trashRecording(at: audioURL, unlinkFrom: current)
        audioRelPath = ""
        audioStatus = "Recording moved to Trash."
    }

    /// Recordings under `<notes>/Audio/`, each with its folder-relative label
    /// (e.g. `2026/2026-08/25/Meeting_….m4a`) and its notes-relative path (as
    /// stored in `gw_audio`) for the picker.
    private func availableRecordings() -> [(url: URL, label: String, rel: String)] {
        let audioPrefix = AppSettings.shared.notesFolder.appendingPathComponent("Audio").path + "/"
        return store.audioRecordings().map { url -> (URL, String, String) in
            let rel = AppSettings.shared.relativePath(of: url)                        // e.g. Audio/2026/…/x.m4a
            let label = url.path.hasPrefix(audioPrefix)                               // e.g. 2026/…/x.m4a
                ? String(url.path.dropFirst(audioPrefix.count)) : rel
            return (url, label, rel)
        }.sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
    }

    /// Map of `gw_audio` relative path → owning note title, across the catalog —
    /// so the picker can flag recordings already linked elsewhere.
    private func audioAssignments() -> [String: String] {
        var map: [String: String] = [:]
        for n in store.doc.notes {
            if let text = store.url(of: n).readText(),
               let rel = FrontMatter.field("gw_audio", in: text), !rel.isEmpty {
                map[rel] = n.title
            }
        }
        return map
    }

    /// Link an audio file to this note. A file already inside the notes folder is
    /// referenced in place; one chosen from elsewhere is copied into the managed
    /// `Audio/` tree (dated like the note) first. Stores the folder-relative path.
    private func assignAudio(_ url: URL) {
        let notes = AppSettings.shared.notesFolder
        let root = notes.path + "/"
        var target = url
        if !url.path.hasPrefix(root) {
            let dir = AppSettings.shared.audioDestinationFolder(for: note.date ?? Date())
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent(url.lastPathComponent)
            do {
                if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
                try FileManager.default.copyItem(at: url, to: dest)
                target = dest
            } catch {
                audioStatus = "Couldn't copy the audio file."
                return
            }
        }
        let rel = AppSettings.shared.relativePath(of: target)
        MeetingNotesWriter.setAudioPath(rel, to: fileURL)
        audioRelPath = rel
        audioStatus = "Recording linked."
    }

    /// Pick any audio file from disk to link.
    private func chooseAudioFile() {
        if let url = FilePanels.openFile(contentTypes: [.audio],
                                         directory: AppSettings.shared.notesFolder.appendingPathComponent("Audio"),
                                         prompt: "Link") {
            assignAudio(url)
        }
    }

    /// The assign/change menu — recordings from the Audio folder split into those
    /// not yet linked and those already linked to another note (flagged, still
    /// selectable), plus a file picker.
    @ViewBuilder private var assignRecordingMenu: some View {
        Menu {
            let recs = availableRecordings()
            let assigned = audioAssignments()
            let free = recs.filter { assigned[$0.rel] == nil || $0.rel == audioRelPath }
            let taken = recs.filter { assigned[$0.rel] != nil && $0.rel != audioRelPath }
            if !free.isEmpty {
                Section("Available") {
                    ForEach(free, id: \.url) { rec in Button(rec.label) { assignAudio(rec.url) } }
                }
            }
            if !taken.isEmpty {
                Section("Linked to another note") {
                    ForEach(taken, id: \.url) { rec in
                        Button("\(rec.label)  —  \(assigned[rec.rel] ?? "")") { assignAudio(rec.url) }
                    }
                }
            }
            Divider()
            Button { chooseAudioFile() } label: { Label("Choose file…", systemImage: "folder") }
        } label: {
            Label(audioRelPath.isEmpty ? "Assign recording" : "Change recording",
                  systemImage: "waveform.badge.plus")
        }
    }

    /// People grouped under the type hierarchy for the Add-person picker,
    /// excluding those already on the note. Type headers with no addable people
    /// are omitted so the tree stays tight.
    private func peoplePickRows(excluding taken: [String]) -> [ChipPickRow] {
        let takenSet = Set(taken)
        var rows: [ChipPickRow] = []
        func emit(_ type: CatalogPersonType, _ depth: Int) {
            let avail = store.people(ofType: type.id).filter { !takenSet.contains($0.id) }
            let kids = store.childPersonTypes(of: type.id)
            // Skip a header only if neither it nor its descendants add anything.
            let before = rows.count
            rows.append(ChipPickRow(id: "type:\(type.id)", name: type.name, depth: depth, isHeader: true))
            for p in avail { rows.append(ChipPickRow(id: p.id, name: p.name, depth: depth + 1)) }
            for c in kids { emit(c, depth + 1) }
            if rows.count == before + 1 { rows.removeLast() }   // header added nothing
        }
        for root in store.rootPersonTypes { emit(root, 0) }
        let untyped = store.people(ofType: nil).filter { !takenSet.contains($0.id) }
        if !untyped.isEmpty {
            rows.append(ChipPickRow(id: "type:none", name: "No type", isHeader: true))
            for p in untyped { rows.append(ChipPickRow(id: p.id, name: p.name, depth: 1)) }
        }
        return rows
    }

    var body: some View {
        Form {
            Section {
                Button { openNote(note) } label: { Label("Open note", systemImage: "arrow.up.forward.app") }
                // Editable title — writes the Catalog row and the file front-matter.
                TextField("Title", text: $titleDraft)
                    .onSubmit(commitTitle)
                if let d = note.date { LabeledContent("Date") { Text(d.formatted(date: .abbreviated, time: .shortened)) } }
                // Meeting type — correct the template a note was filed under.
                if isMeetingNote {
                    Picker("Meeting type", selection: Binding(
                        get: { meetingTypeID },
                        set: { newID in
                            meetingTypeID = newID
                            MeetingNotesWriter.setMeetingType(newID, to: fileURL)
                        })) {
                        ForEach(AppSettings.shared.groupedTemplates, id: \.title) { group in
                            Section(group.title) {
                                ForEach(group.templates, id: \.id) { t in Text(t.displayName).tag(t.id) }
                            }
                        }
                    }
                }
            }

            // Retained recording: play / re-transcribe / delete when linked, or
            // manually link one (from the Audio folder or any file) when not.
            if isMeetingNote {
                Section("Recording") {
                    let linked = !audioRelPath.isEmpty && FileManager.default.fileExists(atPath: audioURL.path)
                    if linked {
                        Text(audioRelPath).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        Button { NSWorkspace.shared.open(audioURL) } label: {
                            Label("Play recording", systemImage: "play.circle")
                        }
                        Button { NSWorkspace.shared.activateFileViewerSelecting([audioURL]) } label: {
                            Label("Reveal in Finder", systemImage: "folder")
                        }
                        Button { regenerateFromAudio() } label: {
                            Label("Re-transcribe → new note", systemImage: "arrow.triangle.2.circlepath")
                        }.disabled(audioBusy)
                        assignRecordingMenu
                        Button {
                            MeetingNotesWriter.setAudioPath("", to: fileURL)
                            audioRelPath = ""; audioStatus = "Link cleared (file kept)."
                        } label: { Label("Unlink (keep file)", systemImage: "link.badge.minus") }
                            .disabled(audioBusy)
                        Button(role: .destructive) { deleteRecording() } label: {
                            Label("Delete recording", systemImage: "trash")
                        }.disabled(audioBusy)
                    } else {
                        if !audioRelPath.isEmpty {
                            Text("Linked recording is missing.").font(.caption).foregroundStyle(.orange)
                            Button("Clear reference") {
                                MeetingNotesWriter.setAudioPath("", to: fileURL); audioRelPath = ""
                            }
                        } else {
                            Text("No recording linked.").font(.caption).foregroundStyle(.secondary)
                        }
                        assignRecordingMenu
                    }
                    if !audioStatus.isEmpty {
                        Text(audioStatus).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            // Single "Filed under": the note's project OR org, as removable
            // chips. One Assign… control handles both (mutually exclusive).
            Section("Filed under") {
                let projs = store.doc.projects.filter { current.projectIDs.contains($0.id) }
                let orgsDirect = store.orgsSorted.filter { current.orgIDs.contains($0.id) }
                if projs.isEmpty && orgsDirect.isEmpty {
                    Text("Unassigned").font(.caption).foregroundStyle(.secondary)
                } else {
                    FlowChips {
                        ForEach(projs) { p in
                            Chip(text: store.projectPath(of: p.id), color: .teal) { store.setProject(p.id, on: note.id, false) }
                        }
                        ForEach(orgsDirect) { o in
                            Chip(text: store.orgPath(of: o.id), color: .blue) { store.setOrg(o.id, on: note.id, false) }
                        }
                    }
                }
                Button { showAssign = true } label: { Label("Assign…", systemImage: "plus.circle") }
                    .buttonStyle(.plain).foregroundStyle(.tint).font(.callout)
                    .popover(isPresented: $showAssign) {
                        AssignPopover(store: store, noteID: note.id, show: $showAssign)
                    }
                // Inherited context (read-only): the org resolved up the
                // project hierarchy, when not directly assigned.
                let viaProject = store.effectiveOrgIDs(of: current).subtracting(current.orgIDs)
                if !viaProject.isEmpty {
                    Text("Org via project: " + store.orgsSorted.filter { viaProject.contains($0.id) }
                        .map { store.orgPath(of: $0.id) }.joined(separator: ", "))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }

            Section("People") {
                let selected = store.doc.people.filter { current.personIDs.contains($0.id) }.sortedByName
                if selected.isEmpty {
                    Text("None").font(.caption).foregroundStyle(.secondary)
                } else {
                    FlowChips {
                        ForEach(selected) { p in
                            Chip(text: p.name, color: .teal) { store.setPerson(p.id, on: note.id, false) }
                        }
                    }
                }
                AddChipButton(
                    title: "Add person…", placeholder: "Search people",
                    options: store.doc.people.sortedByName
                        .filter { !current.personIDs.contains($0.id) }.map { ($0.id, $0.name) },
                    hierarchy: peoplePickRows(excluding: current.personIDs),
                    onPick: { store.setPerson($0, on: note.id, true) },
                    onCreate: { store.setPerson(store.addPerson(name: $0).id, on: note.id, true) })
            }

            Section("Tags") {
                let selected = store.tagsSorted.filter { current.tagIDs.contains($0.id) }
                if selected.isEmpty {
                    Text("None").font(.caption).foregroundStyle(.secondary)
                } else {
                    FlowChips {
                        ForEach(selected) { t in
                            Chip(text: "#\(t.name)", color: .pink) { store.setTag(t.id, on: note.id, false) }
                        }
                    }
                }
                AddChipButton(
                    title: "Add tag…", placeholder: "Search tags",
                    options: store.tagsSorted
                        .filter { !current.tagIDs.contains($0.id) }.map { ($0.id, $0.name) },
                    onPick: { store.setTag($0, on: note.id, true) },
                    onCreate: { store.setTag(store.addTag(name: $0).id, on: note.id, true) })
            }

            // Words the note's own front-matter suggests — each can become any
            // entity type (they route differently), so this is its own section.
            let suggestions = store.suggestedTags(for: current)
            if !suggestions.isEmpty {
                Section {
                    FlowChips {
                        ForEach(suggestions, id: \.self) { token in
                            PromoteMenu(store: store, noteID: note.id, token: token, asChip: true) {}
                        }
                    }
                } header: {
                    Text("From this note")
                } footer: {
                    Text("Words pulled from the note — tap one to add it as a tag, person, project, or organisation.")
                        .font(.caption2)
                }
            }

            NoteActionItemsSection(url: store.url(of: current))
        }
        .formStyle(.grouped)
        .navigationTitle(current.title)
        .onAppear { titleDraft = current.title; loadMeetingType() }
        .onDisappear(perform: commitTitle)
    }
}

// MARK: Chip-editor building blocks

/// A pill showing a selected value with a remove (✕) button.
struct Chip: View {
    let text: String
    var color: Color = .blue
    var onRemove: () -> Void
    var body: some View {
        HStack(spacing: 4) {
            Text(text).font(.caption).lineLimit(1)
            Button(action: onRemove) { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                .buttonStyle(.plain)
        }
        .foregroundStyle(color)
        .pillBackground(color, opacity: 0.16, hPad: 8, vPad: 3)
    }
}

/// Simple wrapping layout for chips.
struct FlowChips<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { FlowLayout(spacing: 6) { content } }
}

/// A "+ add…" button that opens a searchable picker of existing options, with a
/// "Create …" row when the query matches nothing.
/// One row of a hierarchical `AddChipButton` picker — either a non-selectable
/// grouping header (e.g. a person type) or a pickable option, indented by depth.
struct ChipPickRow: Identifiable {
    let id: String
    let name: String
    var depth: Int = 0
    var isHeader: Bool = false
}

struct AddChipButton: View {
    let title: String
    let placeholder: String
    let options: [(id: String, name: String)]
    /// Optional grouped/indented rows shown while the search box is empty
    /// (e.g. people under their type). Searching falls back to the flat
    /// `options` match list. Headers are skipped from selection.
    var hierarchy: [ChipPickRow]? = nil
    let onPick: (String) -> Void
    let onCreate: (String) -> Void
    @State private var show = false
    @State private var query = ""

    var body: some View {
        Button { show = true } label: { Label(title, systemImage: "plus.circle").font(.callout) }
            .buttonStyle(.plain).foregroundStyle(.tint)
            .popover(isPresented: $show) {
                let q = query.trimmingCharacters(in: .whitespaces)
                let matches = options.filter { q.isEmpty || $0.name.localizedCaseInsensitiveContains(q) }
                let exact = options.contains { $0.name.caseInsensitiveCompare(q) == .orderedSame }
                let showTree = q.isEmpty && (hierarchy?.isEmpty == false)
                VStack(spacing: 6) {
                    EntitySearchBar(text: $query, placeholder: placeholder)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            // Picking does NOT dismiss — the chosen item drops out
                            // of the options (recomputed by the parent) so you can
                            // add several in a row. Click away to close.
                            if showTree {
                                ForEach(hierarchy!) { row in
                                    if row.isHeader {
                                        Text(row.name).font(.caption.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                            .padding(.leading, CGFloat(row.depth) * 12).padding(.top, 3)
                                    } else {
                                        Button { onPick(row.id); query = "" } label: {
                                            HStack { Text(row.name); Spacer(); Image(systemName: "plus") }
                                                .contentShape(Rectangle())
                                        }.buttonStyle(.plain)
                                        .padding(.leading, CGFloat(row.depth) * 12)
                                    }
                                }
                            } else {
                                ForEach(matches, id: \.id) { opt in
                                    Button { onPick(opt.id); query = "" } label: {
                                        HStack { Text(opt.name); Spacer(); Image(systemName: "plus") }
                                            .contentShape(Rectangle())
                                    }.buttonStyle(.plain)
                                }
                            }
                            if !q.isEmpty && !exact {
                                Button { onCreate(q); query = "" } label: {
                                    Label("Create “\(q)”", systemImage: "plus.circle.fill")
                                }.buttonStyle(.plain).foregroundStyle(.tint)
                            }
                            if matches.isEmpty && q.isEmpty {
                                Text("Nothing left to add").font(.caption).foregroundStyle(.secondary)
                            }
                            if matches.isEmpty && !q.isEmpty && exact {
                                Text("Already added").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 4)
                    }
                    .frame(maxHeight: 220)
                }
                .padding(10).frame(width: 250)
            }
    }
}

/// The Assign… picker: choose a project OR an organisation (mutually
/// exclusive). Assigning clears the other side via the store helpers.
struct AssignPopover: View {
    @ObservedObject var store: CatalogStore
    let noteID: String
    @Binding var show: Bool
    @State private var query = ""

    var body: some View {
        VStack(spacing: 8) {
            EntitySearchBar(text: $query, placeholder: "Search organisations & projects")
            let rows = store.orgProjectRows(matching: query)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if rows.isEmpty {
                        Text("No organisations or projects").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(rows) { r in
                        Button {
                            if r.kind == "org" { store.setOrg(r.id, on: noteID, true) }
                            else { store.setProject(r.id, on: noteID, true) }
                            show = false
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: r.kind == "org" ? "building.2" : "folder")
                                    .font(.caption2).foregroundStyle(.secondary).frame(width: 14)
                                Text(r.name).lineLimit(1)
                                Spacer()
                            }
                            .padding(.leading, CGFloat(r.depth) * 14)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 4)
            }
            .frame(maxHeight: 260)
        }
        .padding(10).frame(width: 300)
    }

}

/// Action items parsed from the note file, with tick + export-to-Reminders,
/// mirroring the Catalog. Scrolls when there are many.
struct NoteActionItemsSection: View {
    let url: URL
    @State private var items: [NotesLibrary.ActionItem] = []
    @State private var message = ""

    var body: some View {
        Section {
            if items.isEmpty {
                Text("No action items in this note.").font(.caption).foregroundStyle(.secondary)
            } else {
                // All items shown (the form scrolls) so none are hidden.
                ForEach(items) { item in
                    HStack(spacing: 8) {
                        Button { toggle(item) } label: {
                            Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(item.done ? Color.green : Color.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.displayText).strikethrough(item.done)
                            HStack(spacing: 6) {
                                if let owner = item.owner { Text("@\(owner)") }
                                if let due = item.due { Text("due \(due)") }
                            }.font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { export([item]) } label: { Image(systemName: "bell.badge") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .help("Export to Reminders")
                    }
                }
            }
        } header: {
            HStack {
                Text("Action items")
                Spacer()
                if !items.isEmpty {
                    Button("Export all to Reminders") { export(items) }.font(.caption)
                }
            }
        } footer: {
            if !message.isEmpty { Text(message).font(.caption2).foregroundStyle(.secondary) }
        }
        .onAppear(perform: load)
    }

    private func load() { items = NotesLibrary.actionItems(inFile: url) }
    private func toggle(_ item: NotesLibrary.ActionItem) { _ = NotesLibrary.toggleDone(item); load() }
    private func export(_ list: [NotesLibrary.ActionItem]) {
        Task { @MainActor in
            do { let n = try await RemindersExporter.export(list); message = "Exported \(n) to Reminders" }
            catch { message = "Export failed: \(error.localizedDescription)" }
        }
    }
}

/// "Add as ▾" menu that turns a token into any catalog entity and wires it into
/// the note's hierarchy (people attach to the note; a project files the note under it).
struct PromoteMenu: View {
    @ObservedObject var store: CatalogStore
    let noteID: String
    let token: String
    var asChip = false
    var onDone: () -> Void

    private var note: CatalogNote? { store.note(id: noteID) }

    var body: some View {
        Menu {
            // Assigned to the note:
            Button { let t = store.addTag(name: token); store.setTag(t.id, on: noteID, true); onDone() }
                label: { Label("Tag", systemImage: "tag") }
            Button(action: addPerson) { Label("Person", systemImage: "person") }
            Button(action: addProject) { Label("Project", systemImage: "folder") }
            Divider()
            // Created only — assign it yourself:
            Button { _ = store.addOrg(name: token); onDone() }
                label: { Label("Organisation (create only)", systemImage: "building.2") }
        } label: {
            if asChip {
                HStack(spacing: 4) {
                    Text(token).font(.caption).lineLimit(1)
                    Image(systemName: "plus").font(.system(size: 8, weight: .bold))
                }
                .foregroundStyle(.secondary)
                .pillBackground(.secondary, opacity: 0.15, hPad: 8, vPad: 3)
            } else {
                Label("Add as", systemImage: "plus.circle")
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func addPerson() {
        let p = store.addPerson(name: token)
        store.setPerson(p.id, on: noteID, true)   // attach directly to the note, like tags
        onDone()
    }
    private func addProject() {
        // New project inherits the note's current org (if any), then files the note under it.
        let orgID = note.flatMap { store.effectiveOrgIDs(of: $0).first }
        let p = store.addProject(name: token, orgID: orgID)
        store.setProject(p.id, on: noteID, true)
        onDone()
    }
}

// MARK: Map — the whole catalog as one pickable tree
