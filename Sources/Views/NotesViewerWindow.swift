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

    /// Open a notes file in a viewer (used from the menu and Catalog). When
    /// "open notes in external editor" is on, hand the file to the OS default
    /// app (e.g. VS Code) instead.
    static func present(fileURL: URL) {
        if AppSettings.shared.openNotesExternally {
            NSWorkspace.shared.open(fileURL)
            return
        }
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
        window.contentView = NSHostingView(rootView: NotesViewerView(
            fileURL: fileURL, initialText: initialText, regenerate: regenerate,
            documentTitle: fileURL == nil ? title : nil))
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
    /// The window title for generated drafts (nil for file-backed notes) —
    /// drives the draft header's kind, title, and subtitle.
    let documentTitle: String?
    @State private var text: String
    @State private var savedText: String
    @State private var status: String = ""
    @State private var drafting = false
    @State private var summarizing = false
    @State private var regenerating = false
    /// Locked (read-only) by default; unlock to edit. Drafts with no backing
    /// file open unlocked since editing is the whole point.
    @State private var isEditable: Bool
    // Preview-mode find + outline navigation.
    @State private var showFind = false
    @State private var findQuery = ""
    @State private var findIndex = 0
    @State private var outlineTarget: Int?

    init(fileURL: URL?, initialText: String,
         regenerate: (@MainActor () async throws -> String)? = nil,
         documentTitle: String? = nil) {
        self.fileURL = fileURL
        self.regenerate = regenerate
        self.documentTitle = documentTitle
        _text = State(initialValue: initialText)
        _savedText = State(initialValue: initialText)
        // Everything — notes AND generated drafts (AI summary, follow-up) —
        // opens in the rendered view; unlock to edit the raw Markdown.
        _isEditable = State(initialValue: false)
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

    private var isDraft: Bool { fileURL == nil }

    var body: some View {
        VStack(spacing: 0) {
            if isDraft { draftHeader; Divider() }

            // Reading → rendered Markdown; editing → raw monospaced editor.
            if isEditable {
                FindableTextEditor(text: $text, isEditable: true)
            } else {
                VStack(spacing: 0) {
                    if showFind { findBar; Divider() }
                    MarkdownReadView(markdown: text, interactive: fileURL != nil,
                                     onToggleTask: toggleTask,
                                     matchedBlocks: showFind ? Set(findMatches) : [],
                                     activeBlock: showFind ? activeMatchBlock : outlineTarget)
                }
                .background(
                    Button("") { if !isEditable { showFind = true } }
                        .keyboardShortcut("f", modifiers: .command).hidden())
            }

            Divider()
            if isDraft { draftToolbar } else { fileToolbar }
        }
        .frame(minWidth: 460, minHeight: 380)
    }

    // MARK: Preview find + outline

    private var previewBlocks: [MarkdownParse.Block] { MarkdownParse.blocks(text) }

    /// Block indices whose text contains the query (case-insensitive).
    private var findMatches: [Int] {
        let q = findQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard showFind, !q.isEmpty else { return [] }
        return previewBlocks.enumerated().compactMap {
            MarkdownParse.plainText($1).lowercased().contains(q) ? $0 : nil
        }
    }

    private var activeMatchBlock: Int? {
        guard !findMatches.isEmpty else { return nil }
        return findMatches[min(findIndex, findMatches.count - 1)]
    }

    /// Headings (≤ H3) and timestamped chapter bullets, as jump targets.
    private var outline: [(idx: Int, title: String, indent: Int)] {
        previewBlocks.enumerated().compactMap { i, b in
            switch b {
            case .heading(let level, let t) where level <= 3:
                return (i, t, level - 1)
            case .bullet(let t, _, _)
                where t.range(of: #"^\[\d{1,2}:\d{2}(:\d{2})?\]"#, options: .regularExpression) != nil:
                return (i, t, 1)
            default:
                return nil
            }
        }
    }

    private func stepMatch(_ delta: Int) {
        guard !findMatches.isEmpty else { return }
        findIndex = (findIndex + delta + findMatches.count) % findMatches.count
    }

    private var findBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
            TextField("Find in note", text: $findQuery)
                .textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                .onSubmit { stepMatch(1) }
                .onChange(of: findQuery) { _, _ in findIndex = 0 }
            if !findQuery.isEmpty {
                Text(findMatches.isEmpty ? "0/0" : "\(min(findIndex, findMatches.count - 1) + 1)/\(findMatches.count)")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            Button { stepMatch(-1) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.plain).disabled(findMatches.isEmpty).help("Previous match")
            Button { stepMatch(1) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.plain).disabled(findMatches.isEmpty).help("Next match")
            Button { showFind = false; findQuery = "" } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).keyboardShortcut(.cancelAction).help("Close find")
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(.bar)
    }

    // MARK: Draft (AI summary / follow-up) chrome

    /// Classifies a generated draft from its window title so the header can
    /// show the right icon, tint, and label.
    private enum DraftKind {
        case summary, followUp, generic
        var icon: String {
            switch self { case .summary: return "sparkles"; case .followUp: return "envelope"; case .generic: return "doc.text" }
        }
        var tint: Color {
            switch self { case .summary: return .purple; case .followUp: return .blue; case .generic: return .gray }
        }
        var label: String {
            switch self { case .summary: return "AI Summary"; case .followUp: return "Follow-up Draft"; case .generic: return "Draft" }
        }
    }

    private var draftKind: DraftKind {
        let t = (documentTitle ?? "").lowercased()
        if t.hasPrefix("summary") { return .summary }
        if t.hasPrefix("follow-up") || t.hasPrefix("followup") { return .followUp }
        return .generic
    }

    /// The bit after "— " in the draft title (e.g. the meeting it's about).
    private var draftSubtitle: String? {
        guard let t = documentTitle, let dash = t.range(of: "—") else { return nil }
        let s = t[dash.upperBound...].trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? nil : s
    }

    private var draftHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: draftKind.icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(draftKind.tint.gradient, in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 1) {
                Text(draftKind.label).font(.headline)
                if let sub = draftSubtitle {
                    Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if regenerating || summarizing || drafting {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .background(.bar)
    }

    private var draftToolbar: some View {
        HStack(spacing: 8) {
            Button {
                isEditable.toggle()
            } label: {
                Label(isEditable ? "Preview" : "Edit", systemImage: isEditable ? "eye" : "pencil")
            }
            .help(isEditable ? "Switch back to the rendered preview" : "Edit the raw Markdown")

            if regenerate != nil {
                Button { runRegenerate() } label: { Label("Regenerate", systemImage: "arrow.clockwise") }
                    .disabled(regenerating)
                    .help("Discard the cached result and generate a fresh one")
            }

            Spacer()

            if !status.isEmpty {
                Text(status).font(.caption).foregroundStyle(.secondary).transition(.opacity)
            }

            Menu {
                Button { exportPDF() } label: { Label("Export PDF…", systemImage: "arrow.down.doc") }
                Button { saveAs() } label: { Label("Save As…", systemImage: "square.and.arrow.down") }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton).fixedSize()

            Button { copyToPasteboard() } label: {
                Label(isEditable ? "Copy Markdown" : "Copy", systemImage: "doc.on.doc")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .help(isEditable ? "Copy the raw Markdown"
                             : "Copy formatted text — pastes with styling into Mail, docs, etc.")
        }
        .padding(10)
        .animation(.default, value: status)
    }

    // MARK: File-note toolbar

    private var fileToolbar: some View {
        HStack(spacing: 8) {
            Button {
                isEditable.toggle()
                status = isEditable ? "Editing" : "Reading"
            } label: {
                Label(isEditable ? "Preview" : "Edit", systemImage: isEditable ? "eye" : "pencil")
            }
            .help(isEditable ? "Switch back to the rendered preview"
                             : "Edit the raw Markdown (with find & replace)")

            // Preview-only: jump-to outline and find.
            if !isEditable {
                if !outline.isEmpty {
                    Menu {
                        ForEach(outline, id: \.idx) { item in
                            Button(String(repeating: "   ", count: item.indent) + item.title) {
                                outlineTarget = item.idx
                            }
                        }
                    } label: { Label("Outline", systemImage: "list.bullet.indent") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help("Jump to a chapter or section")
                }
                Button { showFind.toggle() } label: {
                    Label("Find", systemImage: "magnifyingglass")
                }
                .help("Find in this note (⌘F)")
            }

            Button { copyToPasteboard() } label: {
                Label(isEditable ? "Copy Markdown" : "Copy", systemImage: "doc.on.doc")
            }
            .help(isEditable ? "Copy the raw Markdown"
                             : "Copy formatted text — pastes with styling into Mail, docs, etc.")

            Button { exportPDF() } label: { Label("Export PDF", systemImage: "arrow.down.doc") }

            if canSummarize {
                Button { summarize() } label: { Label("Summarize", systemImage: "sparkles") }
                    .disabled(summarizing)
                    .help("Open a short AI summary of this note in a new window")
            }
            if canDraftFollowUp {
                Menu {
                    let suggested = suggestedDrafts(for: text)
                    if !suggested.isEmpty {
                        Section("Suggested") {
                            ForEach(suggested) { kind in
                                Button { draftDoc(.builtIn(kind)) } label: {
                                    Label(kind.displayName, systemImage: kind.icon)
                                }
                            }
                        }
                    }
                    ForEach(AppSettings.shared.groupedDraftDocs, id: \.title) { group in
                        Section(group.title) {
                            ForEach(group.docs) { doc in
                                Button { draftDoc(doc) } label: {
                                    Label(doc.displayName, systemImage: doc.icon)
                                }
                            }
                        }
                    }
                    Divider()
                    Button("Auto — match meeting type") { draftAutoFollowUp() }
                } label: {
                    Label("Draft…", systemImage: "doc.badge.plus")
                }
                .disabled(drafting)
                .help("Draft a document from this meeting — minutes, follow-up email, status update, and more")
            }

            Spacer()

            if !status.isEmpty {
                Text(status).font(.caption).foregroundColor(.secondary)
            }

            Menu {
                if let fileURL {
                    Button { NSWorkspace.shared.open(fileURL) } label: { Label("Open in Default App", systemImage: "arrow.up.forward.app") }
                    Button { NSWorkspace.shared.activateFileViewerSelecting([fileURL]) } label: { Label("Reveal in Finder", systemImage: "folder") }
                }
                if isMeetingNote, let fileURL {
                    Button { NotificationCenter.default.post(name: .renameSpeakersForFile, object: fileURL) } label: { Label("Rename Speakers", systemImage: "person.crop.circle") }
                }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()

            Button("Save") { save() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!isDirty || !isEditable)
        }
        .padding(10)
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

    /// The `gw_meeting_type` recorded in the note's front-matter, if present —
    /// the ground truth for what kind of meeting this was.
    private func recordedMeetingTypeID(_ content: String) -> String? {
        FrontMatter.field("gw_meeting_type", in: content)
    }

    /// The drafts to feature for this note — from the recorded meeting type
    /// when available (exact), otherwise inferred from the headings (best-guess).
    private func suggestedDrafts(for content: String) -> [FollowUpKind] {
        if let id = recordedMeetingTypeID(content), let t = MeetingTemplate(rawValue: id) {
            return t.suggestedDrafts
        }
        return MeetingTemplate.inferred(fromNotes: content)?.suggestedDrafts ?? []
    }

    /// Draft a specific output-document type (MoM, follow-up email, status
    /// update, …). Each kind caches independently, so drafting one never
    /// clobbers another for the same meeting.
    private func draftDoc(_ doc: DraftDoc) {
        guard let fileURL, let transcript = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        let base = fileURL.deletingPathExtension().lastPathComponent
        let guidance = doc.guidance
        let title = doc.displayName
        drafting = true
        status = "Drafting…"
        Task { @MainActor in
            defer { drafting = false }
            do {
                let draft = try await TextPolisher().draftDocument(transcript: transcript, guidance: guidance)
                status = ""
                NotesViewerWindowController.present(
                    draftTitle: "\(title) — \(base)",
                    text: draft,
                    regenerate: { try await TextPolisher().draftDocument(transcript: transcript, guidance: guidance, forceRefresh: true) })
            } catch {
                status = "Draft failed: \(error.localizedDescription)"
            }
        }
    }

    /// Auto follow-up: shape the draft to the note's recorded meeting type when
    /// present, else the type inferred from its headings, else the default.
    private func draftAutoFollowUp() {
        guard let fileURL, let transcript = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        let base = fileURL.deletingPathExtension().lastPathComponent
        drafting = true
        status = "Drafting…"
        let template = recordedMeetingTypeID(transcript).flatMap { AppSettings.shared.template(withID: $0) }
            ?? MeetingTemplate.inferred(fromNotes: transcript).map { SummaryTemplate.builtIn($0) }
            ?? AppSettings.shared.selectedTemplate
        Task { @MainActor in
            defer { drafting = false }
            do {
                let draft = try await TextPolisher().draftFollowUp(transcript: transcript, template: template)
                status = ""
                NotesViewerWindowController.present(
                    draftTitle: "Follow-up (\(template.displayName)) — \(base)",
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

    /// Copy adapts to the current mode:
    /// - Edit (raw): copies the raw Markdown verbatim.
    /// - Preview (rendered): copies formatted rich text (RTF) with a clean
    ///   plain-text fallback, so pasting into Mail / Gmail / docs keeps the
    ///   headings, bold, and bullets — and pasting into a code field stays clean.
    private func copyToPasteboard() {
        let pb = NSPasteboard.general
        if isEditable {
            pb.clearContents()
            pb.setString(text, forType: .string)
            status = "Copied Markdown"
            return
        }
        if let attr = try? NSAttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .full,
                           failurePolicy: .returnPartiallyParsedIfPossible)) {
            pb.clearContents()
            pb.declareTypes([.rtf, .string], owner: nil)
            if let rtf = attr.rtf(from: NSRange(location: 0, length: attr.length),
                                  documentAttributes: [:]) {
                pb.setData(rtf, forType: .rtf)
            }
            pb.setString(attr.string, forType: .string)   // markdown-stripped plain text
        } else {
            pb.clearContents()
            pb.setString(text, forType: .string)
        }
        status = "Copied"
    }

    /// Flip a task checkbox from read mode and persist immediately — so Agenda
    /// and Action Items can be ticked without unlocking to edit. `line` is the
    /// index into the current text's lines (from the renderer).
    private func toggleTask(line: Int) {
        var lines = text.components(separatedBy: "\n")
        guard line >= 0, line < lines.count else { return }
        let l = lines[line]
        if let r = l.range(of: "[ ]") {
            lines[line] = l.replacingCharacters(in: r, with: "[x]")
        } else if let r = l.range(of: "[x]") ?? l.range(of: "[X]") {
            lines[line] = l.replacingCharacters(in: r, with: "[ ]")
        } else {
            return
        }
        let updated = lines.joined(separator: "\n")
        text = updated
        savedText = updated                       // stay in sync so it's not "dirty"
        if let fileURL {
            try? updated.write(to: fileURL, atomically: true, encoding: .utf8)
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

// MARK: - Rendered Markdown (read mode)

/// A lightweight SwiftUI Markdown renderer for read mode — headings, bullets,
/// task lists, block quotes, code fences, rules, and inline bold/italic/code/
/// links — plus a compact "Properties" box for YAML front-matter. Text stays
/// selectable. Editing switches back to the raw monospaced editor.
private struct MarkdownReadView: View {
    let markdown: String
    /// When true, task checkboxes are tappable and toggle the backing file.
    var interactive: Bool = false
    var onToggleTask: (Int) -> Void = { _ in }
    /// Block indices to highlight (search matches); the active match is tinted
    /// more strongly and scrolled into view.
    var matchedBlocks: Set<Int> = []
    var activeBlock: Int? = nil

    /// Comfortable reading measure — long notes shouldn't stretch full width.
    private let maxTextWidth: CGFloat = 720

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    let blocks = MarkdownParse.blocks(markdown)
                    ForEach(Array(blocks.enumerated()), id: \.offset) { idx, block in
                        row(block, previous: idx > 0 ? blocks[idx - 1] : nil,
                            matched: matchedBlocks.contains(idx), active: activeBlock == idx)
                            .id(idx)
                    }
                }
                .frame(maxWidth: maxTextWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .textSelection(.enabled)
                .padding(.horizontal, 26)
                .padding(.vertical, 22)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: activeBlock) { _, target in
                guard let target else { return }
                withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(target, anchor: .center) }
            }
        }
    }

    @ViewBuilder
    private func row(_ block: MarkdownParse.Block, previous: MarkdownParse.Block?,
                     matched: Bool, active: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Rhythm: generous space above a new section heading, tight between
            // consecutive list items, comfortable otherwise.
            Spacer().frame(height: topGap(for: block, previous: previous))
            content(block)
                .padding(.horizontal, matched ? 4 : 0)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(active ? Color.accentColor.opacity(0.28)
                              : matched ? Color.yellow.opacity(0.28) : Color.clear))
        }
    }

    @ViewBuilder
    private func content(_ block: MarkdownParse.Block) -> some View {
        switch block {
        case .heading(let level, let text):
            VStack(alignment: .leading, spacing: 5) {
                Text(MarkdownParse.inline(text))
                    .font(headingFont(level))
                    .foregroundStyle(.primary)
                    .textCase(level >= 4 ? .uppercase : nil)
                if level <= 2 {
                    Divider().opacity(0.6)
                }
            }

        case .paragraph(let text):
            if MarkdownParse.isBoldLabel(text) {
                Text(MarkdownParse.inline(text))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
            } else {
                Text(MarkdownParse.inline(text))
                    .font(.system(size: 14))
                    .lineSpacing(4)
                    .foregroundStyle(.primary.opacity(0.9))
            }

        case .bullet(let text, let marker, let depth):
            if marker == nil, MarkdownParse.isBoldLabel(text) {
                // A bullet that's just a bold label (e.g. "**Action Items:**")
                // reads as a sub-heading, not a list item — so drop the dot.
                Text(MarkdownParse.inline(text))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .padding(.leading, CGFloat(depth) * 18)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    if let marker {
                        Text(marker).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                            .frame(minWidth: 16, alignment: .trailing)
                    } else {
                        Circle().fill(Color.accentColor.opacity(0.65))
                            .frame(width: 5, height: 5)
                            .padding(.top, 6).frame(width: 16, alignment: .trailing)
                    }
                    Text(MarkdownParse.inline(text)).font(.system(size: 14)).lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.leading, CGFloat(depth) * 18)
            }

        case .task(let done, let text, let line, let depth):
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Button {
                    onToggleTask(line)
                } label: {
                    Image(systemName: done ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(done ? Color.accentColor : Color.secondary.opacity(0.6))
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .disabled(!interactive)
                .help(interactive ? (done ? "Mark as not done" : "Mark as done") : "")
                Text(MarkdownParse.inline(text))
                    .font(.system(size: 14)).lineSpacing(3)
                    .foregroundStyle(done ? Color.secondary : Color.primary.opacity(0.9))
                    .strikethrough(done, color: Color.secondary.opacity(0.6))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, CGFloat(depth) * 18)

        case .quote(let text):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(Color.accentColor.opacity(0.5)).frame(width: 3)
                Text(MarkdownParse.inline(text)).font(.system(size: 14).italic())
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 6).padding(.trailing, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.06)))

        case .code(let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code).font(.system(size: 12.5, design: .monospaced)).padding(11)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.secondary.opacity(0.12)))

        case .rule:
            Divider().opacity(0.5)

        case .frontMatter(let body):
            FrontMatterView(raw: body)

        case .table(let headers, let rows):
            let cols = max(1, headers.count)
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 7) {
                    GridRow {
                        ForEach(Array(headers.enumerated()), id: \.offset) { _, h in
                            Text(MarkdownParse.inline(h))
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.primary)
                        }
                    }
                    Divider().gridCellColumns(cols)
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(0..<cols, id: \.self) { c in
                                Text(MarkdownParse.inline(c < row.count ? row[c] : ""))
                                    .font(.system(size: 13))
                                    .foregroundStyle(.primary.opacity(0.9))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
                .padding(11)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.03)))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.secondary.opacity(0.12)))
        }
    }

    /// Spacing above each block, so headings breathe and list items stay tight.
    private func topGap(for block: MarkdownParse.Block, previous: MarkdownParse.Block?) -> CGFloat {
        guard let previous else { return 0 }
        switch block {
        case .heading(let level, _): return level <= 2 ? 22 : 16
        case .bullet(let text, let marker, _):
            if marker == nil, MarkdownParse.isBoldLabel(text) { return 13 }   // sub-heading
            if case .bullet = previous { return 4 }
            if case .task = previous { return 4 }
            return 10
        case .task:
            if case .task = previous { return 4 }
            if case .bullet = previous { return 4 }
            return 10
        case .rule: return 14
        default: return 10
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1:  return .system(size: 23, weight: .bold)
        case 2:  return .system(size: 18, weight: .semibold)
        case 3:  return .system(size: 15, weight: .semibold)
        default: return .system(size: 12, weight: .semibold)
        }
    }
}

/// Renders YAML front-matter as a tidy card: array fields (tags, attendees)
/// become wrapped chips, scalar fields become label · value rows.
private struct FrontMatterView: View {
    let raw: String

    private struct Field: Identifiable { let id = UUID(); let key: String; let values: [String] }

    private var fields: [Field] {
        raw.split(separator: "\n").compactMap { line -> Field? in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var val = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !val.isEmpty else { return nil }
            if val.hasPrefix("[") && val.hasSuffix("]") {
                val = String(val.dropFirst().dropLast())
                let items = val.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                return items.isEmpty ? nil : Field(key: key, values: items)
            }
            return Field(key: key, values: [val.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))])
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(fields) { field in
                if field.values.count > 1 || field.key == "tags" {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(field.key.uppercased())
                            .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                            .tracking(0.5)
                        FlowLayout(spacing: 6) {
                            ForEach(field.values, id: \.self) { chip(field.key, $0) }
                        }
                    }
                } else {
                    HStack(spacing: 8) {
                        Text(field.key.uppercased())
                            .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                            .tracking(0.5).frame(width: 90, alignment: .leading)
                        Text(Self.pretty(field.values[0])).font(.system(size: 12)).foregroundStyle(.primary.opacity(0.85))
                    }
                }
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.secondary.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.secondary.opacity(0.1)))
    }

    /// Render ISO-8601 timestamps (the front-matter `date:` field) as a
    /// friendly "03 Jul 2026 at 2:30 PM"; leave everything else untouched.
    static func pretty(_ value: String) -> String {
        guard let date = isoDate(value) else { return value }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private static func isoDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }

    @ViewBuilder
    private func chip(_ key: String, _ value: String) -> some View {
        let isPerson = key == "attendees" || key == "people"
        HStack(spacing: 4) {
            Image(systemName: isPerson ? "person.fill" : "number")
                .font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 11, weight: .medium))
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(Color.accentColor.opacity(0.14)))
        .foregroundStyle(.primary.opacity(0.85))
    }
}

/// A minimal wrapping layout for chip rows (macOS 13+ `Layout`).
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Minimal block-level Markdown parser for the read-mode renderer. Not a full
/// CommonMark implementation — just the constructs GhostWriter's notes use.
private enum MarkdownParse {
    enum Block {
        case heading(level: Int, text: String)
        case paragraph(String)
        case bullet(text: String, marker: String?, depth: Int)   // marker nil → unordered
        case task(done: Bool, text: String, line: Int, depth: Int)   // line: index into the file's lines
        case quote(String)
        case code(String)
        case rule
        case frontMatter(String)
        case table(headers: [String], rows: [[String]])
    }

    /// The searchable / outline plain text of a block.
    static func plainText(_ b: Block) -> String {
        switch b {
        case .heading(_, let t): return t
        case .paragraph(let t): return t
        case .quote(let t): return t
        case .bullet(let t, _, _): return t
        case .task(_, let t, _, _): return t
        case .code(let c): return c
        case .frontMatter(let f): return f
        case .table(let h, let rows): return (h + rows.flatMap { $0 }).joined(separator: " ")
        case .rule: return ""
        }
    }

    /// Inline styling (bold/italic/code/links) via AttributedString, falling
    /// back to plain text if the fragment doesn't parse.
    static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }

    static func blocks(_ md: String) -> [Block] {
        var out: [Block] = []
        let lines = md.components(separatedBy: "\n")
        var i = 0

        // Leading YAML front-matter → a Properties box.
        if lines.first == "---" {
            var fm: [String] = []
            var j = 1
            while j < lines.count, lines[j] != "---" { fm.append(lines[j]); j += 1 }
            if j < lines.count {
                let body = fm.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !body.isEmpty { out.append(.frontMatter(body)) }
                i = j + 1
            }
        }

        var para: [String] = []
        func flushPara() {
            let joined = para.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !joined.isEmpty { out.append(.paragraph(joined)) }
            para.removeAll()
        }

        while i < lines.count {
            let rawLine = lines[i]
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let depth = indentDepth(rawLine)

            if line.hasPrefix("```") {
                flushPara()
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[i]); i += 1
                }
                out.append(.code(code.joined(separator: "\n")))
                i += 1   // skip closing fence
                continue
            }
            if line.isEmpty { flushPara(); i += 1; continue }
            if line == "---" || line == "***" || line == "___" {
                flushPara(); out.append(.rule); i += 1; continue
            }
            if line.hasPrefix("#"),
               let sp = line.firstIndex(of: " "),
               case let level = line.distance(from: line.startIndex, to: sp),
               level >= 1, level <= 6,
               line.prefix(level).allSatisfy({ $0 == "#" }) {
                flushPara()
                out.append(.heading(level: level, text: String(line[line.index(after: sp)...])))
                i += 1; continue
            }
            if line.hasPrefix(">") {
                flushPara()
                out.append(.quote(line.dropFirst().trimmingCharacters(in: .whitespaces)))
                i += 1; continue
            }
            if let task = matchTask(line) {
                flushPara(); out.append(.task(done: task.done, text: task.text, line: i, depth: depth)); i += 1; continue
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                flushPara()
                out.append(.bullet(text: String(line.dropFirst(2)), marker: nil, depth: depth)); i += 1; continue
            }
            if let ord = matchOrdered(line) {
                flushPara(); out.append(.bullet(text: ord.text, marker: ord.marker, depth: depth)); i += 1; continue
            }
            // GFM pipe table: a header row followed by a --- | --- separator.
            if line.contains("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                flushPara()
                let headers = splitRow(line)
                var rows: [[String]] = []
                i += 2   // consume header + separator
                while i < lines.count {
                    let l = lines[i].trimmingCharacters(in: .whitespaces)
                    if l.isEmpty || !l.contains("|") { break }
                    rows.append(splitRow(l)); i += 1
                }
                out.append(.table(headers: headers, rows: rows)); continue
            }
            para.append(line); i += 1
        }
        flushPara()
        return out
    }

    /// A GFM table separator row, e.g. "| --- | :--: |" — only pipes, dashes,
    /// colons, and spaces, with at least one dash and one pipe.
    static func isTableSeparator(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.contains("-"), t.contains("|") else { return false }
        return t.allSatisfy { $0 == "|" || $0 == "-" || $0 == ":" || $0 == " " }
    }

    /// Split a table row on "|", trimming cells and dropping the empty edges
    /// produced by leading/trailing pipes.
    static func splitRow(_ s: String) -> [String] {
        var cells = s.trimmingCharacters(in: .whitespaces)
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if cells.first == "" { cells.removeFirst() }
        if cells.last == "" { cells.removeLast() }
        return cells
    }

    /// True when a line is entirely one bold span (optionally trailing ":"),
    /// e.g. "**Action Items:**" — treated as a sub-heading, not a bullet.
    static func isBoldLabel(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        let inner = t.hasSuffix(":") ? String(t.dropLast()) : t
        guard inner.hasPrefix("**"), inner.hasSuffix("**"), inner.count > 4 else { return false }
        return !inner.dropFirst(2).dropLast(2).contains("**")
    }

    /// Nesting depth from leading whitespace (2 spaces / 1 tab = one level),
    /// capped so deeply-indented content doesn't march off the right edge.
    static func indentDepth(_ s: String) -> Int {
        var spaces = 0
        for c in s {
            if c == " " { spaces += 1 } else if c == "\t" { spaces += 2 } else { break }
        }
        return min(4, spaces / 2)
    }

    private static func matchTask(_ line: String) -> (done: Bool, text: String)? {
        for bullet in ["- ", "* ", "+ "] where line.hasPrefix(bullet) {
            let rest = String(line.dropFirst(bullet.count))
            if rest.hasPrefix("[ ] ") { return (false, String(rest.dropFirst(4))) }
            if rest.lowercased().hasPrefix("[x] ") { return (true, String(rest.dropFirst(4))) }
        }
        return nil
    }

    private static func matchOrdered(_ line: String) -> (marker: String, text: String)? {
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        let after = line.dropFirst(digits.count)
        guard after.hasPrefix(". ") else { return nil }
        return (marker: "\(digits).", text: String(after.dropFirst(2)))
    }
}
