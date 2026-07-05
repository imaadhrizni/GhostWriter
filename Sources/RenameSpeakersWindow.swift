import SwiftUI
import AppKit

// MARK: - Rename Speakers
//
// Give "Them / Them 2" real names — per meeting. Pick any meeting, rename its
// speakers, and only that notes file is rewritten. When the chosen meeting is
// the one currently recording, future segments use the new names too.

final class RenameSpeakersWindowController: NSWindowController {

    /// - Parameters:
    ///   - liveFile: the currently recording meeting's file, if any
    ///   - onRename: called per changed label (old, new, file) after the rewrite
    convenience init(liveFile: URL?, onRename: @escaping (String, String, URL) -> Void) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 340),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.center()
        window.title = "Rename Speakers"

        self.init(window: window)
        window.contentView = NSHostingView(rootView: RenameSpeakersView(
            liveFile: liveFile, onRename: onRename,
            close: { [weak window] in window?.close() }))
    }

    func showAndActivate() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct RenameSpeakersView: View {
    let liveFile: URL?
    let onRename: (String, String, URL) -> Void
    let close: () -> Void

    @State private var files: [URL] = []
    @State private var selected: URL?
    @State private var labels: [String] = []
    @State private var names: [String: String] = [:]

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
                    ForEach(labels, id: \.self) { label in
                        TextField(label, text: Binding(
                            get: { names[label] ?? label },
                            set: { names[label] = $0 }
                        ))
                    }
                }
                Spacer()
            }

            HStack {
                Spacer()
                Button("Cancel") { close() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!hasChanges)
            }
        }
        .padding(16)
        .frame(width: 400, height: 340)
        .onAppear {
            files = MeetingNotesWriter.allMeetingFiles(under: AppSettings.shared.notesFolder)
            selected = liveFile ?? files.first
            rescan()
        }
        .onChange(of: selected) { _, _ in rescan() }
    }

    private func displayName(of file: URL) -> String {
        file.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "Meeting_", with: "")
            .replacingOccurrences(of: "_", with: " ")
    }

    private func rescan() {
        names = [:]
        labels = selected.map { MeetingNotesWriter.speakerLabels(in: $0) } ?? []
    }

    private var hasChanges: Bool {
        labels.contains { label in
            let new = (names[label] ?? label).trimmingCharacters(in: .whitespaces)
            return !new.isEmpty && new != label
        }
    }

    private func save() {
        guard let file = selected else { return }
        for label in labels {
            let new = (names[label] ?? label).trimmingCharacters(in: .whitespaces)
            guard !new.isEmpty, new != label else { continue }
            MeetingNotesWriter.renameSpeaker(from: label, to: new, in: file)
            onRename(label, new, file)
        }
        close()
    }
}
