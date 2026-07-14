import SwiftUI
import AppKit

// MARK: - Ask Your Knowledge Base
//
// A persistent, multi-turn chat over the WHOLE meeting archive. Each question
// retrieves the most relevant excerpts (on-device semantic search when
// available, keyword otherwise), then answers with cited sources you can click
// to open. Follow-up questions carry the recent conversation for context, so
// "what about pricing?" resolves against the prior turn.

final class AskWindowController: NSWindowController {
    private static var shared: AskWindowController?

    /// Open the Ask window (reusing the existing one if already open).
    static func present() {
        if let existing = shared, existing.window?.isVisible == true {
            existing.bringToFront(); return
        }
        let controller = AskWindowController()
        shared = controller
        controller.bringToFront()
    }

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.center()
        window.title = "Ask Your Notes"
        window.titlebarAppearsTransparent = true
        super.init(window: window)
        window.contentView = NSHostingView(rootView: AskView())
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

}

// MARK: - View

private struct AskMessage: Identifiable {
    enum Role { case user, assistant }
    let id = UUID()
    let role: Role
    var text: String
    var citations: [NotesLibrary.ExcerptResult.Citation] = []
    var source: String? = nil   // "Groq" / "Apple Intelligence", for assistant turns
}

/// What subset of the archive a question is answered from.
private enum AskScope: Equatable {
    case all
    case meetings(Set<URL>)
    case org(String)
    case project(String)
}

private struct AskView: View {
    @State private var messages: [AskMessage] = []
    @State private var draft = ""
    @State private var asking = false
    @State private var scope: AskScope = .all
    @State private var showMeetingPicker = false
    // Tree-picker selection, mapped to `scope` (org/project/all).
    @State private var scopeKind = ""
    @State private var scopeID = ""

    var body: some View {
        VStack(spacing: 0) {
            scopeBar
            Divider()
            if messages.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(messages) { MessageRow(message: $0) }
                            if asking { thinkingRow }
                        }
                        .padding(14)
                    }
                    .onChange(of: messages.count) { _, _ in
                        if let last = messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                    }
                }
            }

            Divider()

            HStack(spacing: 8) {
                TextField("Ask about your meetings…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .onSubmit(send)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .textBackgroundColor)))
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .disabled(asking || draft.trimmingCharacters(in: .whitespaces).isEmpty)
                if !messages.isEmpty {
                    Button {
                        messages = []
                    } label: { Image(systemName: "trash") }
                        .buttonStyle(.plain).help("Clear the conversation")
                }
            }
            .padding(12)
        }
        .frame(minWidth: 460, minHeight: 420)
    }

    // MARK: Scope

    private var scopeBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease.circle").foregroundStyle(.secondary)
            // Same tree picker used across the app — scope by any org or project.
            OrgProjectTreePicker(store: CatalogStore.shared, kind: $scopeKind, id: $scopeID,
                                 allLabel: "All meetings", allIcon: "tray.full")
            Button("Choose meetings…") { showMeetingPicker = true }
                .buttonStyle(.link).font(.callout)
            if case .meetings(let urls) = scope, !urls.isEmpty {
                Text("\(urls.count) selected").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .popover(isPresented: $showMeetingPicker) { meetingPicker }
        // The tree picker sets kind then id; recompute the scope from both.
        .onChange(of: scopeKind) { _, _ in applyTreeScope() }
        .onChange(of: scopeID) { _, _ in applyTreeScope() }
    }

    private func applyTreeScope() {
        switch scopeKind {
        case "org" where !scopeID.isEmpty:     scope = .org(scopeID)
        case "project" where !scopeID.isEmpty:  scope = .project(scopeID)
        default:                                 scope = .all
        }
    }

    private var meetingPicker: some View {
        let files = NotesLibrary.meetingFiles(limit: 60)
        let selected: Set<URL> = { if case .meetings(let s) = scope { return s } else { return [] } }()
        return VStack(alignment: .leading, spacing: 0) {
            Text("Choose meetings").font(.headline).padding(10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(files) { f in
                        Toggle(isOn: Binding(
                            get: { selected.contains(f.url) },
                            set: { on in
                                var s = selected
                                if on { s.insert(f.url) } else { s.remove(f.url) }
                                scope = s.isEmpty ? .all : .meetings(s)
                            })) {
                            Text(f.displayName).font(.callout)
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                .padding(10)
            }
            .frame(width: 320, height: 300)
        }
    }

    /// The files to scope retrieval to, or nil for the whole archive.
    private func resolvedFiles() -> [NotesLibrary.MeetingFile]? {
        let store = CatalogStore.shared
        switch scope {
        case .all:
            return nil
        case .meetings(let urls):
            return urls.map(NotesLibrary.MeetingFile.init)
        case .org(let id):
            return store.notes(forOrg: id, includingDescendants: true)
                .map { NotesLibrary.MeetingFile(url: store.url(of: $0)) }
        case .project(let id):
            return store.notes(forProject: id)
                .map { NotesLibrary.MeetingFile(url: store.url(of: $0)) }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 40)).foregroundStyle(.tertiary)
            Text("Ask your whole meeting archive")
                .font(.headline)
            Text("“What did we decide about pricing with Acme?”\n“Summarize the DESC compliance thread.”\n“What are my open commitments to the platform team?”")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var thinkingRow: some View {
        HStack(spacing: 6) {
            ProgressView().scaleEffect(0.6)
            Text("Searching your notes…").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func send() {
        let q = draft.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, !asking else { return }
        draft = ""
        messages.append(AskMessage(role: .user, text: q))
        asking = true

        // Recent turns for follow-up context (kept short).
        let history = messages.suffix(6).map {
            "\($0.role == .user ? "Q" : "A"): \($0.text)"
        }.joined(separator: "\n")
        let files = resolvedFiles()

        Task { @MainActor in
            defer { asking = false }
            let result = await Self.answer(question: q, history: history, files: files)
            messages.append(AskMessage(role: .assistant, text: result.text,
                                       citations: result.citations, source: result.engine))
        }
    }

    private struct Answer { let text: String; let citations: [NotesLibrary.ExcerptResult.Citation]; let engine: String? }

    /// Retrieve excerpts across the archive and answer, with an on-device
    /// fallback when Groq is unavailable or fails. Retrieval is hybrid
    /// (meaning + keyword), so it works even without an embedding model.
    private static func answer(question: String, history: String,
                               files: [NotesLibrary.MeetingFile]?) async -> Answer {
        if let files, files.isEmpty {
            return Answer(text: "That scope has no meetings to search. Pick a different scope.", citations: [], engine: nil)
        }
        let retrieved = files == nil
            ? await NotesLibrary.semanticExcerpts(for: question)
            : await NotesLibrary.semanticExcerpts(for: question, files: files!)
        guard !retrieved.text.isEmpty else {
            return Answer(text: "I couldn't find anything relevant in this scope. Try rewording, widening the scope, or check that you have meetings recorded.", citations: [], engine: nil)
        }

        let framed = history.isEmpty
            ? question
            : "Conversation so far:\n\(history)\n\nAnswer this follow-up: \(question)"

        // Cloud first (unless Local-only / prefer-on-device), Apple fallback.
        let localFirst = AppSettings.shared.localOnlyMode || AppSettings.shared.preferOnDeviceAI
        if !localFirst {
            do {
                let text = try await TextPolisher().answerAcrossMeetings(question: framed, excerpts: retrieved.text)
                return Answer(text: text, citations: retrieved.citations, engine: "Groq")
            } catch {
                // fall through to on-device
            }
        }
        if let local = await AppleIntelligence.generate(
            instructions: """
            You answer questions using ONLY the provided meeting excerpts, grouped under "=== Meeting … ===" headers. \
            Cite which meeting each point comes from. Be concise. If the excerpts don't contain the answer, say so — never guess.
            """,
            prompt: "Excerpts:\n\(retrieved.text)\n\n\(framed)") {
            return Answer(text: local, citations: retrieved.citations, engine: "Apple Intelligence")
        }
        return Answer(text: "Couldn't reach an AI model to answer. Check your Groq key, or enable Apple Intelligence for on-device answers.", citations: [], engine: nil)
    }
}

private struct MessageRow: View {
    let message: AskMessage

    /// A short preview of the cited chunk with matched query terms bolded and
    /// tinted. Trims to a window around the first matched term when the chunk
    /// is long, so the relevant phrase is what's shown.
    static func highlighted(_ text: String, terms: [String]) -> AttributedString {
        let lower = text.lowercased()
        // Center the preview on the earliest matched term (offset-based so the
        // lowercased search maps cleanly back onto the original string).
        var startOffset = 0
        let firstOffsets = terms.compactMap { term -> Int? in
            guard let r = lower.range(of: term) else { return nil }
            return lower.distance(from: lower.startIndex, to: r.lowerBound)
        }
        if let earliest = firstOffsets.min() {
            startOffset = max(0, earliest - 40)
        }
        let start = text.index(text.startIndex, offsetBy: startOffset, limitedBy: text.endIndex) ?? text.startIndex
        var preview = String(text[start...].prefix(220))
        if startOffset > 0 { preview = "…" + preview }

        var attr = AttributedString(preview)
        let previewLower = preview.lowercased()
        for term in Set(terms.map { $0.lowercased() }) {
            var searchStart = previewLower.startIndex
            while let r = previewLower.range(of: term, range: searchStart..<previewLower.endIndex) {
                let lo = previewLower.distance(from: previewLower.startIndex, to: r.lowerBound)
                let hi = previewLower.distance(from: previewLower.startIndex, to: r.upperBound)
                let aLo = attr.index(attr.startIndex, offsetByCharacters: lo)
                let aHi = attr.index(attr.startIndex, offsetByCharacters: hi)
                attr[aLo..<aHi].inlinePresentationIntent = .stronglyEmphasized
                attr[aLo..<aHi].foregroundColor = .primary
                searchStart = r.upperBound
            }
        }
        return attr
    }

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 6) {
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 12)
                        .fill(message.role == .user
                              ? Color.accentColor.opacity(0.18)
                              : Color(nsColor: .quaternaryLabelColor).opacity(0.4)))
                if !message.citations.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(message.citations) { cite in
                            Button {
                                NotesViewerWindowController.present(fileURL: cite.file.url)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Label(cite.file.displayName, systemImage: "doc.text")
                                        .font(.caption)
                                    if !cite.snippet.isEmpty {
                                        Text(MessageRow.highlighted(cite.snippet, terms: cite.terms))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                }
                            }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.leading, 4)
                }
                if let engine = message.source {
                    Text("via \(engine)").font(.caption2).foregroundStyle(.tertiary).padding(.leading, 4)
                }
            }
            if message.role == .assistant { Spacer(minLength: 40) }
        }
        .id(message.id)
    }
}
