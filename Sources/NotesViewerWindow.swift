import SwiftUI
import AppKit

// MARK: - Notes Viewer / Editor
//
// A lightweight in-app Markdown viewer + editor for a single notes file, so
// reading or fixing a note doesn't require leaving for Finder. Also used to
// present a generated follow-up draft (no backing file — Copy / Save As).

final class NotesViewerWindowController: NSWindowController {

    /// Retain presented viewers so their windows aren't deallocated; closed
    /// ones are pruned on the next present.
    private static var open: [NotesViewerWindowController] = []

    /// Open a notes file in a viewer (used from the menu and Notes Assistant).
    static func present(fileURL: URL) {
        open.removeAll { $0.window?.isVisible == false }
        let controller = NotesViewerWindowController(fileURL: fileURL)
        open.append(controller)
        controller.showAndActivate()
    }

    /// Present generated draft text in a viewer.
    static func present(draftTitle: String, text: String) {
        open.removeAll { $0.window?.isVisible == false }
        let controller = NotesViewerWindowController(draftTitle: draftTitle, text: text)
        open.append(controller)
        controller.showAndActivate()
    }

    /// Open an existing notes file for viewing/editing.
    convenience init(fileURL: URL) {
        let text = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        self.init(title: fileURL.lastPathComponent, fileURL: fileURL, initialText: text)
    }

    /// Present generated text (e.g. a follow-up draft) with no backing file.
    convenience init(draftTitle: String, text: String) {
        self.init(title: draftTitle, fileURL: nil, initialText: text)
    }

    private convenience init(title: String, fileURL: URL?, initialText: String) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.center()
        window.title = title
        window.titlebarAppearsTransparent = true

        self.init(window: window)
        window.contentView = NSHostingView(rootView: NotesViewerView(fileURL: fileURL, initialText: initialText))
    }

    func showAndActivate() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct NotesViewerView: View {
    let fileURL: URL?
    @State private var text: String
    @State private var savedText: String
    @State private var status: String = ""
    @State private var drafting = false

    init(fileURL: URL?, initialText: String) {
        self.fileURL = fileURL
        _text = State(initialValue: initialText)
        _savedText = State(initialValue: initialText)
    }

    private var isDirty: Bool { text != savedText }

    /// Speaker labels only exist in meeting notes.
    private var isMeetingNote: Bool {
        fileURL?.lastPathComponent.hasPrefix("Meeting_") ?? false
    }

    /// A follow-up can be drafted from any saved meeting note (needs network).
    private var canDraftFollowUp: Bool {
        isMeetingNote && !AppSettings.shared.localOnlyMode
    }

    var body: some View {
        VStack(spacing: 0) {
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .padding(8)

            Divider()

            HStack(spacing: 8) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    status = "Copied"
                } label: { Label("Copy", systemImage: "doc.on.doc") }

                Button {
                    exportPDF()
                } label: { Label("Export PDF", systemImage: "arrow.down.doc") }

                if let fileURL {
                    Button {
                        NSWorkspace.shared.open(fileURL)
                    } label: { Label("Open in Default App", systemImage: "arrow.up.forward.app") }

                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                    } label: { Label("Reveal in Finder", systemImage: "folder") }
                }

                if isMeetingNote, let fileURL {
                    Button {
                        NotificationCenter.default.post(name: .renameSpeakersForFile, object: fileURL)
                    } label: { Label("Rename Speakers", systemImage: "person.crop.circle") }
                }

                if canDraftFollowUp {
                    Button {
                        draftFollowUp()
                    } label: { Label("Draft Follow-up", systemImage: "envelope") }
                        .disabled(drafting)
                }

                Spacer()

                if !status.isEmpty {
                    Text(status).font(.caption).foregroundColor(.secondary)
                }

                if fileURL != nil {
                    Button("Save") { save() }
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(!isDirty)
                } else {
                    Button("Save As…") { saveAs() }
                }
            }
            .padding(10)
        }
        .frame(minWidth: 420, minHeight: 360)
    }

    private func draftFollowUp() {
        guard let fileURL, let transcript = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        drafting = true
        status = "Drafting…"
        // Infer the meeting type from the note's headings so the draft matches
        // (customer email vs internal debrief etc.); fall back to the default.
        let template = MeetingTemplate.inferred(fromNotes: transcript).map { SummaryTemplate.builtIn($0) }
            ?? AppSettings.shared.selectedTemplate
        Task { @MainActor in
            defer { drafting = false }
            do {
                let draft = try await TextPolisher().draftFollowUp(transcript: transcript, template: template)
                status = ""
                NotesViewerWindowController.present(
                    draftTitle: "Follow-up — \(fileURL.deletingPathExtension().lastPathComponent)",
                    text: draft)
            } catch {
                status = "Draft failed: \(error.localizedDescription)"
            }
        }
    }

    /// Render the current Markdown to a paginated PDF and let the user save it.
    private func exportPDF() {
        let base = fileURL?.deletingPathExtension().lastPathComponent ?? "Note"
        guard let pdf = MarkdownPDF.data(from: text, title: base) else {
            status = "Export failed: could not render PDF"; return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = base + ".pdf"
        panel.directoryURL = fileURL?.deletingLastPathComponent() ?? AppSettings.shared.notesFolder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try pdf.write(to: url)
            status = "Exported \(url.lastPathComponent)"
        } catch {
            status = "Export failed: \(error.localizedDescription)"
        }
    }

    private func save() {
        guard let fileURL else { return }
        do {
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
            savedText = text
            status = "Saved"
        } catch {
            status = "Save failed: \(error.localizedDescription)"
        }
    }

    private func saveAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "Follow-up.md"
        panel.directoryURL = AppSettings.shared.notesFolder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            status = "Saved to \(url.lastPathComponent)"
        } catch {
            status = "Save failed: \(error.localizedDescription)"
        }
    }
}
