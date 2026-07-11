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
    var sources: [NotesLibrary.MeetingFile] = []
    var source: String? = nil   // "Groq" / "Apple Intelligence", for assistant turns
}

/// What subset of the archive a question is answered from.
private enum AskScope: Equatable {
    case all
    case meetings(Set<URL>)
    case org(String)
    case opportunity(String)
}

private struct AskView: View {
    @State private var messages: [AskMessage] = []
    @State private var draft = ""
    @State private var asking = false
    @State private var scope: AskScope = .all
    @State private var showMeetingPicker = false

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
            Menu {
                Button("All meetings") { scope = .all }
                Button("Choose meetings…") { showMeetingPicker = true }
                let store = CatalogStore.shared
                if !store.doc.opportunities.isEmpty {
                    Menu("By opportunity") {
                        ForEach(store.doc.opportunities.sortedByName) { opp in
                            Button(opp.name) { scope = .opportunity(opp.id) }
                        }
                    }
                }
                if !store.orgsSorted.isEmpty {
                    Menu("By organisation") {
                        ForEach(store.orgsSorted) { org in
                            Button(org.name) { scope = .org(org.id) }
                        }
                    }
                }
            } label: {
                Text(scopeLabel).font(.callout)
            }
            .menuStyle(.borderlessButton).fixedSize()
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .popover(isPresented: $showMeetingPicker) { meetingPicker }
    }

    private var scopeLabel: String {
        switch scope {
        case .all: return "All meetings"
        case .meetings(let urls): return urls.isEmpty ? "All meetings" : "\(urls.count) meeting\(urls.count == 1 ? "" : "s")"
        case .org(let id): return CatalogStore.shared.doc.orgs.first { $0.id == id }?.name ?? "Organisation"
        case .opportunity(let id): return CatalogStore.shared.opportunity(id)?.name ?? "Opportunity"
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
        case .opportunity(let id):
            guard let opp = store.opportunity(id) else { return [] }
            return store.notes(forOpportunity: opp)
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
                                       sources: result.sources, source: result.engine))
        }
    }

    private struct Answer { let text: String; let sources: [NotesLibrary.MeetingFile]; let engine: String? }

    /// Retrieve excerpts across the archive and answer, with an on-device
    /// fallback when Groq is unavailable or fails.
    private static func answer(question: String, history: String,
                               files: [NotesLibrary.MeetingFile]?) async -> Answer {
        if let files, files.isEmpty {
            return Answer(text: "That scope has no meetings to search. Pick a different scope.", sources: [], engine: nil)
        }
        let retrieved: NotesLibrary.ExcerptResult
        if NotesLibrary.semanticAvailable {
            retrieved = files == nil
                ? await NotesLibrary.semanticExcerpts(for: question)
                : await NotesLibrary.semanticExcerpts(for: question, files: files!)
        } else {
            retrieved = NotesLibrary.ExcerptResult(text: "", sources: [])
        }
        guard !retrieved.text.isEmpty else {
            return Answer(text: "I couldn't find anything relevant in this scope. Try rewording, widening the scope, or check that you have meetings recorded.", sources: [], engine: nil)
        }

        let framed = history.isEmpty
            ? question
            : "Conversation so far:\n\(history)\n\nAnswer this follow-up: \(question)"

        // Cloud first (unless Local-only / prefer-on-device), Apple fallback.
        let localFirst = AppSettings.shared.localOnlyMode || AppSettings.shared.preferOnDeviceAI
        if !localFirst {
            do {
                let text = try await TextPolisher().answerAcrossMeetings(question: framed, excerpts: retrieved.text)
                return Answer(text: text, sources: retrieved.sources, engine: "Groq")
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
            return Answer(text: local, sources: retrieved.sources, engine: "Apple Intelligence")
        }
        return Answer(text: "Couldn't reach an AI model to answer. Check your Groq key, or enable Apple Intelligence for on-device answers.", sources: [], engine: nil)
    }
}

private struct MessageRow: View {
    let message: AskMessage

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
                if !message.sources.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(message.sources) { src in
                            Button {
                                NotesViewerWindowController.present(fileURL: src.url)
                            } label: {
                                Label(src.displayName, systemImage: "doc.text")
                                    .font(.caption)
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
