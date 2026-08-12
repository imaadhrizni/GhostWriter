import SwiftUI
import AppKit

// MARK: - Recordings hub
//
// One place to see every retained meeting recording under `<notes>/Audio/`
// (across the dated subfolders), with the actions you'd want on each: play,
// reveal, open/​jump to its note, re-transcribe into a fresh note, and a safe
// delete (moves the file to the Trash). Recordings are matched to their note by
// filename stem — a live meeting writes `<note-stem>.m4a` beside its note.

struct RecordingsList: View {
    @ObservedObject var store: CatalogStore
    @State private var recordings: [Rec] = []
    @State private var busyID: URL?
    @State private var status = ""

    struct Rec: Identifiable {
        let url: URL
        let date: Date
        let size: Int64
        let note: CatalogNote?
        var id: URL { url }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if recordings.isEmpty {
                ContentUnavailableView {
                    Label("No recordings", systemImage: "waveform")
                } description: {
                    Text("Meeting audio is saved here when “Retain meeting audio” is on (Settings → Meetings → Recording).")
                }
            } else {
                List(recordings) { rec in row(rec) }
            }
        }
        .onAppear(perform: reload)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("Recordings").font(.headline)
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary) }
            Button { reload() } label: { Image(systemName: "arrow.clockwise") }
                .help("Rescan the Audio folder")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var summary: String {
        guard !recordings.isEmpty else { return "Retained meeting audio" }
        let total = recordings.reduce(Int64(0)) { $0 + $1.size }
        return "\(recordings.count) recording\(recordings.count == 1 ? "" : "s") · \(byteString(total))"
    }

    private func row(_ rec: Rec) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .foregroundStyle(.brown)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(rec.note?.title ?? rec.url.deletingPathExtension().lastPathComponent)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(rec.date.formatted(date: .abbreviated, time: .shortened))
                    Text("· \(byteString(rec.size))")
                    if rec.note == nil { Text("· no linked note").foregroundStyle(.orange) }
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            if busyID == rec.url {
                ProgressView().controlSize(.small)
            } else {
                Button { NSWorkspace.shared.open(rec.url) } label: { Image(systemName: "play.circle") }
                    .buttonStyle(.borderless).help("Play")
                if let note = rec.note {
                    Button { NotesViewerWindowController.present(fileURL: store.url(of: note)) } label: {
                        Image(systemName: "doc.text")
                    }.buttonStyle(.borderless).help("Open the linked note")
                }
                Menu {
                    Button { NSWorkspace.shared.open(rec.url) } label: { Label("Play", systemImage: "play.circle") }
                    Button { NSWorkspace.shared.activateFileViewerSelecting([rec.url]) } label: { Label("Reveal in Finder", systemImage: "folder") }
                    if let note = rec.note {
                        Button { NotesViewerWindowController.present(fileURL: store.url(of: note)) } label: { Label("Open linked note", systemImage: "doc.text") }
                    }
                    if !AppSettings.shared.localOnlyMode {
                        Button { regenerate(rec) } label: { Label("Re-transcribe → new note", systemImage: "arrow.triangle.2.circlepath") }
                    }
                    Divider()
                    Button(role: .destructive) { delete(rec) } label: { Label("Delete recording", systemImage: "trash") }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize()
            }
        }
        .padding(.vertical, 3)
    }

    // MARK: Actions

    /// Enumerate `<notes>/Audio/` (recursively) for `.m4a` files, newest first,
    /// each resolved to its note by filename stem.
    private func reload() {
        recordings = store.audioRecordings().map { url in
            let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            return Rec(
                url: url,
                date: vals?.contentModificationDate ?? .distantPast,
                size: Int64(vals?.fileSize ?? 0),
                note: linkedNote(for: url))
        }.sorted { $0.date > $1.date }
    }

    /// The catalog note a recording belongs to — a note file with the same
    /// filename stem (how a live meeting names its recording).
    private func linkedNote(for audioURL: URL) -> CatalogNote? {
        let stem = audioURL.deletingPathExtension().lastPathComponent
        return store.doc.notes.first {
            URL(fileURLWithPath: $0.filePath).deletingPathExtension().lastPathComponent == stem
        }
    }

    private func regenerate(_ rec: Rec) {
        busyID = rec.url; status = "Re-transcribing \(rec.url.lastPathComponent)…"
        Task { @MainActor in
            defer { busyID = nil }
            let source = rec.note ?? CatalogNote(filePath: "", title: "")
            if let newURL = await AudioImportService.shared.regenerate(fromAudio: rec.url, like: source) {
                status = "New note created."
                NotesViewerWindowController.present(fileURL: newURL)
                reload()
            } else {
                status = "Re-transcription failed."
            }
        }
    }

    /// Safe delete — move the file to the Trash and drop its `gw_audio` link.
    private func delete(_ rec: Rec) {
        store.trashRecording(at: rec.url, unlinkFrom: rec.note)
        status = "Moved \(rec.url.lastPathComponent) to Trash."
        reload()
    }

    private func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
