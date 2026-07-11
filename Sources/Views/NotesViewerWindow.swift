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

    /// Open a notes file in a viewer (used from the menu and Catalog).
    static func present(fileURL: URL) {
        open.removeAll { $0.window?.isVisible == false }
        let controller = NotesViewerWindowController(fileURL: fileURL)
        open.append(controller)
        controller.bringToFront()
    }

    /// Present generated draft text in a viewer. `regenerate`, when given, adds a
    /// "Regenerate" button that discards the cached result and produces a fresh
    /// one (used by AI summaries and follow-up drafts).
    static func present(draftTitle: String, text: String,
                        regenerate: (@MainActor () async throws -> String)? = nil) {
        open.removeAll { $0.window?.isVisible == false }
        let controller = NotesViewerWindowController(draftTitle: draftTitle, text: text, regenerate: regenerate)
        open.append(controller)
        controller.bringToFront()
    }

    /// Open an existing notes file for viewing/editing.
    convenience init(fileURL: URL) {
        let text = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        self.init(title: fileURL.lastPathComponent, fileURL: fileURL, initialText: text)
    }

    /// Present generated text (e.g. a follow-up draft) with no backing file.
    convenience init(draftTitle: String, text: String,
                     regenerate: (@MainActor () async throws -> String)? = nil) {
        self.init(title: draftTitle, fileURL: nil, initialText: text, regenerate: regenerate)
    }

    private convenience init(title: String, fileURL: URL?, initialText: String,
                             regenerate: (@MainActor () async throws -> String)? = nil) {
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
        window.contentView = NSHostingView(rootView: NotesViewerView(fileURL: fileURL, initialText: initialText, regenerate: regenerate))
    }

}

/// An NSTextView-backed editor with the native find bar (⌘F) — SwiftUI's
/// TextEditor doesn't expose one. Monospaced, plain text, two-way bound.
private struct FindableTextEditor: NSViewRepresentable {
    @Binding var text: String
    /// When false the view is read-only: find still works (find-only), but the
    /// text can't be changed and the find bar hides its Replace row.
    var isEditable: Bool

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.allowsUndo = true
        // The TextEdit-style find bar. It shows the Replace row only when the
        // view is editable, so read-only mode is find-only automatically.
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.string = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        if textView.isEditable != isEditable { textView.isEditable = isEditable }
        // Only overwrite when the model changed externally, to avoid disturbing
        // the cursor/selection while the user is typing.
        if textView.string != text { textView.string = text }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            text.wrappedValue = tv.string
        }
    }
}

private struct NotesViewerView: View {
    let fileURL: URL?
    /// For AI-generated drafts: produce a fresh (cache-bypassing) version.
    let regenerate: (@MainActor () async throws -> String)?
    @State private var text: String
    @State private var savedText: String
    @State private var status: String = ""
    @State private var drafting = false
    @State private var summarizing = false
    @State private var regenerating = false
    /// Locked (read-only) by default; unlock to edit. Drafts with no backing
    /// file open unlocked since editing is the whole point.
    @State private var isEditable: Bool

    init(fileURL: URL?, initialText: String, regenerate: (@MainActor () async throws -> String)? = nil) {
        self.fileURL = fileURL
        self.regenerate = regenerate
        _text = State(initialValue: initialText)
        _savedText = State(initialValue: initialText)
        _isEditable = State(initialValue: fileURL == nil)
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

    /// A quick AI summary can be run on any non-empty saved note when cloud is
    /// allowed. (Generated drafts get a "Regenerate" button instead.)
    private var canSummarize: Bool {
        fileURL != nil && !AppSettings.shared.localOnlyMode
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            FindableTextEditor(text: $text, isEditable: isEditable)

            Divider()

            HStack(spacing: 8) {
                if fileURL != nil {
                    Button {
                        isEditable.toggle()
                        status = isEditable ? "Editing enabled" : "Locked"
                    } label: {
                        Label(isEditable ? "Editable" : "Locked",
                              systemImage: isEditable ? "lock.open" : "lock")
                    }
                    .help(isEditable
                          ? "Read/write — click to lock (find-only)"
                          : "Read-only — click to unlock for editing and find & replace")
                }

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    status = "Copied"
                } label: { Label("Copy", systemImage: "doc.on.doc") }

                Button {
                    exportPDF()
                } label: { Label("Export PDF", systemImage: "arrow.down.doc") }

                if canSummarize {
                    Button { summarize() } label: { Label("Summarize", systemImage: "sparkles") }
                        .disabled(summarizing)
                        .help("Open a short AI summary of this note in a new window")
                }

                if regenerate != nil {
                    Button { runRegenerate() } label: { Label("Regenerate", systemImage: "arrow.clockwise") }
                        .disabled(regenerating)
                        .help("Discard the cached result and generate a fresh one")
                }

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
                        .disabled(!isDirty || !isEditable)
                } else {
                    Button("Save As…") { saveAs() }
                }
            }
            .padding(10)
        }
        .frame(minWidth: 420, minHeight: 360)
    }

    /// Quick AI recap of the current note, opened in its own viewer window
    /// (like Draft Follow-up).
    private func summarize() {
        let source = text
        summarizing = true
        status = "Summarizing…"
        let base = fileURL?.deletingPathExtension().lastPathComponent ?? "Note"
        Task { @MainActor in
            defer { summarizing = false }
            do {
                let brief = try await TextPolisher().noteBrief(text: source)
                status = ""
                NotesViewerWindowController.present(
                    draftTitle: "Summary — \(base)", text: TextPolisher.spacedBrief(brief),
                    regenerate: { TextPolisher.spacedBrief(try await TextPolisher().noteBrief(text: source, forceRefresh: true)) })
            } catch {
                status = "Summary failed: \(error.localizedDescription)"
            }
        }
    }

    /// Re-run the generator behind this draft, bypassing the cache, and replace
    /// the shown text with the fresh result.
    private func runRegenerate() {
        guard let regenerate else { return }
        regenerating = true
        status = "Regenerating…"
        Task { @MainActor in
            defer { regenerating = false }
            do {
                text = try await regenerate()
                savedText = text
                status = "Regenerated"
            } catch {
                status = "Regenerate failed: \(error.localizedDescription)"
            }
        }
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
                    text: draft,
                    regenerate: { try await TextPolisher().draftFollowUp(transcript: transcript, template: template, forceRefresh: true) })
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
