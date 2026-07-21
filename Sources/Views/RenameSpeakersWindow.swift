import SwiftUI
import AppKit

// MARK: - Rename Speakers
//
// Identify "Them / Them 2" as real people — per meeting. Pick any meeting,
// assign each speaker to a Catalog person (or create one), and only that notes
// file is rewritten. Assigning a speaker also *teaches that person's voice*, so
// the same voice is recognized automatically in future meetings, and links the
// person to the note in the Catalog. When the chosen meeting is the one
// currently recording, future segments use the new names too.

final class RenameSpeakersWindowController: NSWindowController {

    /// - Parameters:
    ///   - liveFile: the currently recording meeting's file, if any
    ///   - preselect: a specific meeting to open selected (e.g. the note being
    ///     viewed); defaults to the live meeting, then the most recent
    ///   - onRename: called per changed label (old, new, personID, file) after
    ///     the rewrite — `personID` is the linked Catalog person (nil if the new
    ///     name isn't a Catalog person, e.g. a legacy free-text edit)
    convenience init(liveFile: URL?, preselect: URL? = nil,
                     onRename: @escaping (String, String, String?, URL) -> Void) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.center()
        window.title = "Identify Speakers"

        self.init(window: window)
        window.contentView = NSHostingView(rootView: RenameSpeakersView(
            liveFile: liveFile, preselect: preselect, onRename: onRename,
            close: { [weak window] in window?.close() }))
    }

}

private struct RenameSpeakersView: View {
    let liveFile: URL?
    let preselect: URL?
    let onRename: (String, String, String?, URL) -> Void
    let close: () -> Void

    @ObservedObject private var store = CatalogStore.shared
    @State private var files: [URL] = []
    @State private var selected: URL?
    @State private var labels: [String] = []
    /// label → chosen Catalog person id (nil = leave the label unchanged).
    @State private var assignment: [String: String] = [:]
    @State private var newPersonName = ""
    @State private var addingFor: String?

    private var people: [CatalogPerson] { store.doc.people.sortedByName }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Meeting")
                Picker("", selection: $selected) {
                    ForEach(files, id: \.self) { file in
                        Text(displayName(of: file) + (file == liveFile ? "  (recording)" : ""))
                            .tag(Optional(file))
                    }
                }
                .labelsHidden()
            }

            if selected == liveFile, liveFile != nil {
                Label("Meeting in progress — new segments will use these names too.",
                      systemImage: "record.circle")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if labels.isEmpty {
                Spacer()
                Text("No speakers found in this meeting yet.")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                Form {
                    ForEach(labels, id: \.self) { label in speakerRow(label) }
                }
                Text("Assigning a speaker teaches their voice — GhostWriter recognizes them automatically next time — and links the person to this note.")
                    .font(.caption2).foregroundColor(.secondary)
                Spacer()
            }

            HStack {
                Spacer()
                Button("Cancel") { close() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!hasChanges)
            }
        }
        .padding(16)
        .frame(width: 420, height: 360)
        .onAppear {
            files = MeetingNotesWriter.allMeetingFiles(under: AppSettings.shared.notesFolder)
            // Prefer an explicitly requested meeting (the one being viewed),
            // then the live meeting, then the most recent.
            selected = (preselect.map { p in files.contains(p) ? p : nil } ?? nil)
                ?? liveFile ?? files.first
            rescan()
        }
        .onChange(of: selected) { _, _ in rescan() }
    }

    @ViewBuilder
    private func speakerRow(_ label: String) -> some View {
        HStack {
            Text(label).frame(width: 90, alignment: .leading)
            if addingFor == label {
                TextField("New person's name", text: $newPersonName, onCommit: { commitNewPerson(for: label) })
                Button("Add") { commitNewPerson(for: label) }
                    .disabled(newPersonName.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Cancel") { addingFor = nil; newPersonName = "" }
            } else {
                Picker("", selection: Binding(
                    get: { assignment[label] ?? "" },
                    set: { sel in
                        if sel == "__new__" { addingFor = label; newPersonName = "" }
                        else { assignment[label] = sel.isEmpty ? nil : sel }
                    }
                )) {
                    Text("Leave as \(label)").tag("")
                    Divider()
                    ForEach(people) { p in Text(p.name).tag(p.id) }
                    Divider()
                    Text("New person…").tag("__new__")
                }
                .labelsHidden()
            }
        }
    }

    private func commitNewPerson(for label: String) {
        let name = newPersonName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        // Reuse an existing person of the same name, else create one.
        let person = store.doc.people.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            ?? store.addPerson(name: name)
        assignment[label] = person.id
        addingFor = nil
        newPersonName = ""
    }

    private func displayName(of file: URL) -> String {
        file.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "Meeting_", with: "")
            .replacingOccurrences(of: "_", with: " ")
    }

    private func rescan() {
        assignment = [:]
        addingFor = nil
        labels = selected.map { MeetingNotesWriter.speakerLabels(in: $0) } ?? []
    }

    private var hasChanges: Bool {
        labels.contains { assignment[$0] != nil }
    }

    private func save() {
        guard let file = selected else { return }
        for label in labels {
            guard let pid = assignment[label], let person = store.person(pid) else { continue }
            let new = person.name.trimmingCharacters(in: .whitespaces)
            guard !new.isEmpty, new != label else { continue }
            MeetingNotesWriter.renameSpeaker(from: label, to: new, in: file)
            onRename(label, new, pid, file)
        }
        close()
    }
}
