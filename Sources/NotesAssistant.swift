import SwiftUI
import AppKit

// MARK: - Notes Assistant
//
// One window, three tools over the meeting-notes folder:
//   Search       — full-text search across every notes file
//   Ask          — Q&A over one meeting's transcript via the polishing model
//   Action Items — aggregated "## Action Items" sections from recent meetings

final class NotesAssistantWindowController: NSWindowController {
    let model = NotesAssistantModel()

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.center()
        window.title = "Notes Assistant"

        self.init(window: window)
        window.contentView = NSHostingView(rootView: NotesAssistantView(model: model))
    }

    func showAndActivate() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Open straight to the browse-all-notes tab (from the menu).
    func showAllNotes() {
        model.mode = .browse
        showAndActivate()
    }
}

/// Holds the selected tab so the menu can open the window to a specific one.
final class NotesAssistantModel: ObservableObject {
    @Published var mode: AssistantMode = .search
}

// MARK: - Notes folder helpers

private enum NotesLibrary {

    struct MeetingFile: Identifiable, Hashable {
        let url: URL
        var id: URL { url }

        /// "yyyy-MM-dd_HH-mm-ss" from the filename.
        private var stamp: String {
            url.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "Meeting_", with: "")
        }
        /// "2026-07-03" — grouping key matching the folder hierarchy.
        var day: String { String(stamp.prefix(10)) }
        /// "14:30:22"
        var time: String {
            stamp.count > 11
                ? String(stamp.dropFirst(11)).replacingOccurrences(of: "-", with: ":")
                : stamp
        }
        var displayName: String { "\(day) · \(time)" }
    }

    /// Meetings grouped by day, newest day (and meeting) first.
    static func meetingsByDay(limit: Int = 50) -> [(day: String, meetings: [MeetingFile])] {
        var groups: [(day: String, meetings: [MeetingFile])] = []
        for meeting in meetingFiles(limit: limit) {
            if groups.last?.day == meeting.day {
                groups[groups.count - 1].meetings.append(meeting)
            } else {
                groups.append((meeting.day, [meeting]))
            }
        }
        return groups
    }

    static func meetingFiles(limit: Int = 50) -> [MeetingFile] {
        MeetingNotesWriter.allMeetingFiles(under: AppSettings.shared.notesFolder)
            .prefix(limit)
            .map(MeetingFile.init)
    }

    struct SearchHit: Identifiable {
        let id = UUID()
        let file: MeetingFile
        let line: String
    }

    /// Full-text search over the most recent meetings, newest first.
    /// Reads files one at a time and honors Task cancellation so a stale
    /// keystroke's search stops as soon as the next one starts.
    /// Capped at `maxFiles` recent meetings — with an unbounded archive,
    /// reading every file on each keystroke would freeze the window.
    static func search(_ query: String, maxHits: Int = 60,
                       maxFiles: Int = AppSettings.shared.searchDepth) async -> [SearchHit] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { return [] }

        var hits: [SearchHit] = []
        for file in meetingFiles(limit: maxFiles) {
            if Task.isCancelled { return hits }
            guard let content = try? String(contentsOf: file.url, encoding: .utf8) else { continue }
            for line in content.split(whereSeparator: \.isNewline) {
                if line.range(of: trimmed, options: .caseInsensitive) != nil {
                    hits.append(SearchHit(file: file, line: String(line)))
                    if hits.count >= maxHits { return hits }
                }
            }
        }
        return hits
    }

    /// Retrieval for cross-meeting Ask: lines matching any search term, with
    /// a little surrounding context, grouped per meeting and labeled so the
    /// model can cite which meeting an answer came from.
    /// Caps: newest `maxFiles` meetings, `maxChars` total prompt budget.
    struct ExcerptResult {
        let text: String
        let sources: [MeetingFile]   // meetings the excerpts came from, newest first
    }

    static func excerpts(matching terms: [String],
                         contextLines: Int = 2,
                         maxFiles: Int = AppSettings.shared.searchDepth,
                         maxChars: Int = 20_000) -> ExcerptResult {
        let needles = terms.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count >= 2 }
        guard !needles.isEmpty else { return ExcerptResult(text: "", sources: []) }

        var out = ""
        var sources: [MeetingFile] = []
        for file in meetingFiles(limit: maxFiles) {
            if Task.isCancelled || out.count >= maxChars { break }
            guard let content = try? String(contentsOf: file.url, encoding: .utf8) else { continue }
            let lines = content.split(whereSeparator: \.isNewline).map(String.init)

            // Collect matching line indexes ± context, merged into ranges.
            var keep = IndexSet()
            for (i, line) in lines.enumerated() {
                if needles.contains(where: { line.range(of: $0, options: .caseInsensitive) != nil }) {
                    keep.insert(integersIn: max(0, i - contextLines)...min(lines.count - 1, i + contextLines))
                }
            }
            guard !keep.isEmpty else { continue }

            var block = "\n=== Meeting \(file.displayName) ===\n"
            var lastIndex = -2
            for i in keep.sorted() {
                if i > lastIndex + 1 { block += "…\n" }
                block += lines[i] + "\n"
                lastIndex = i
            }
            if out.count + block.count > maxChars { break }
            out += block
            sources.append(file)
        }
        return ExcerptResult(text: out, sources: sources)
    }

    struct ActionItem: Identifiable {
        let id = UUID()
        let file: MeetingFile
        let text: String
        let done: Bool
        /// The exact line in the file — used to toggle done state in place.
        let rawLine: String
    }

    /// Flip an item's checkbox in its notes file. Line-based: finds the
    /// item's exact line (ignoring indentation), rewrites just that line.
    /// Returns false when the line is gone (file edited elsewhere).
    @discardableResult
    static func toggleDone(_ item: ActionItem) -> Bool {
        guard let content = try? String(contentsOf: item.file.url, encoding: .utf8) else { return false }
        var lines = content.components(separatedBy: "\n")
        guard let idx = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == item.rawLine
        }) else { return false }

        // Rebuild the line from clean parts (bullet + one checkbox + text) —
        // idempotent, and repairs any earlier duplicated "[x] [x]" tokens.
        let indent = lines[idx].prefix(while: { $0 == " " || $0 == "\t" })
        let bullet = item.rawLine.hasPrefix("*") ? "*" : "-"
        lines[idx] = "\(indent)\(bullet) [\(item.done ? " " : "x")] \(item.text)"
        do {
            try lines.joined(separator: "\n").write(to: item.file.url, atomically: true, encoding: .utf8)
            return true
        } catch {
            Log.app.error("❌ Could not update action item: \(error.localizedDescription)")
            return false
        }
    }

    struct MeetingActionItems: Identifiable {
        let file: MeetingFile
        let items: [ActionItem]
        var id: URL { file.url }
    }

    /// Bullets under "## Action Items" headings, grouped per meeting,
    /// newest meetings first. Meetings without action items are skipped.
    static func actionItemsByMeeting(
        fromLast meetings: Int = AppSettings.shared.actionItemsLookback) -> [MeetingActionItems] {
        var groups: [MeetingActionItems] = []
        for file in meetingFiles(limit: meetings) {
            guard let content = try? String(contentsOf: file.url, encoding: .utf8) else { continue }
            var items: [ActionItem] = []
            var inSection = false
            for rawLine in content.split(whereSeparator: \.isNewline) {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                if line.lowercased().hasPrefix("## action items") { inSection = true; continue }
                if inSection {
                    if line.hasPrefix("#") { inSection = false; continue }
                    if line.hasPrefix("-") || line.hasPrefix("*") {
                        // "- [ ] item" / "* [x] item" checkboxes (either bullet),
                        // or legacy plain "- item". Strip every leading checkbox
                        // token so a previously duplicated "[x] [x]" self-heals.
                        var text = line.dropFirst().trimmingCharacters(in: .whitespaces)
                        var done = false
                        while text.hasPrefix("[ ]") || text.lowercased().hasPrefix("[x]") {
                            if text.lowercased().hasPrefix("[x]") { done = true }
                            text = text.dropFirst(3).trimmingCharacters(in: .whitespaces)
                        }
                        if !text.isEmpty {
                            items.append(ActionItem(file: file, text: text, done: done, rawLine: line))
                        }
                    }
                }
            }
            if !items.isEmpty { groups.append(MeetingActionItems(file: file, items: items)) }
        }
        return groups
    }
}

// MARK: - Root view

enum AssistantMode: String, CaseIterable, Identifiable {
    case browse = "All Notes", search = "Search", ask = "Ask", actions = "Action Items"
    var id: String { rawValue }
}

struct NotesAssistantView: View {
    @ObservedObject var model: NotesAssistantModel

    var body: some View {
        VStack(spacing: 12) {
            Picker("", selection: $model.mode) {
                ForEach(AssistantMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.top, 12)

            switch model.mode {
            case .browse:  BrowseTab()
            case .search:  SearchTab()
            case .ask:     AskTab()
            case .actions: ActionItemsTab()
            }
        }
        .frame(minWidth: 560, minHeight: 420)
    }
}

// MARK: - Browse (all notes)

private struct BrowseTab: View {
    @State private var groups: [(day: String, meetings: [NotesLibrary.MeetingFile])] = []

    var body: some View {
        Group {
            if groups.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.largeTitle).foregroundColor(.secondary)
                    Text("No meeting notes yet.").foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(groups, id: \.day) { group in
                        Section(header: Text(group.day)) {
                            ForEach(group.meetings) { meeting in
                                Button {
                                    NotesViewerWindowController.present(fileURL: meeting.url)
                                } label: {
                                    HStack {
                                        Image(systemName: "doc.text")
                                            .foregroundColor(.secondary)
                                        Text(meeting.time)
                                        Spacer()
                                        Image(systemName: "arrow.up.forward.square")
                                            .foregroundColor(.secondary)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
        .onAppear { groups = NotesLibrary.meetingsByDay(limit: 500) }
    }
}

// MARK: - Search

private struct SearchTab: View {
    @State private var query = ""
    @State private var hits: [NotesLibrary.SearchHit] = []
    @State private var searchTask: Task<Void, Never>?

    /// Hits per meeting, in arrival (newest-first) order.
    private var groupedHits: [(file: NotesLibrary.MeetingFile, hits: [NotesLibrary.SearchHit])] {
        var groups: [(file: NotesLibrary.MeetingFile, hits: [NotesLibrary.SearchHit])] = []
        for hit in hits {
            if groups.last?.file == hit.file {
                groups[groups.count - 1].hits.append(hit)
            } else {
                groups.append((hit.file, [hit]))
            }
        }
        return groups
    }

    /// Debounce + cancel: typing restarts the timer, and the file reads run
    /// off the main thread so the field never stutters on a large archive.
    private func scheduleSearch(_ q: String) {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            let results = await NotesLibrary.search(q)
            guard !Task.isCancelled else { return }
            await MainActor.run { hits = results }
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("Search all meeting notes…", text: $query)
                    .textFieldStyle(.plain)
                    .onChange(of: query) { _, q in scheduleSearch(q) }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
            .padding(.horizontal, 16)

            if hits.isEmpty {
                Spacer()
                Text(query.trimmingCharacters(in: .whitespaces).count < 2
                     ? "Type to search every meeting transcript."
                     : "No matches.")
                    .foregroundColor(.secondary)
                Spacer()
            } else {
                // Hits arrive newest-meeting-first — group consecutive hits
                // from the same file into one section per meeting.
                List {
                    ForEach(groupedHits, id: \.file.url) { group in
                        Section {
                            ForEach(group.hits) { hit in
                                Button {
                                    NotesViewerWindowController.present(fileURL: hit.file.url)
                                } label: {
                                    Text(hit.line)
                                        .lineLimit(2)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        } header: {
                            Button {
                                NotesViewerWindowController.present(fileURL: group.file.url)
                            } label: {
                                HStack(spacing: 4) {
                                    Text(group.file.displayName)
                                        .font(.subheadline.weight(.semibold))
                                    Image(systemName: "arrow.up.forward.square")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            .help("Open this meeting's notes file")
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }
}

// MARK: - Ask

private struct AskTab: View {
    @State private var meetings = NotesLibrary.meetingFiles(limit: 15)
    @State private var selected: NotesLibrary.MeetingFile?
    @State private var question = ""
    @State private var answer = ""
    @State private var sources: [NotesLibrary.MeetingFile] = []
    @State private var isAsking = false
    @State private var errorMessage: String?

    private let polisher = TextPolisher()

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Meeting")
                Picker("", selection: $selected) {
                    Text("All meetings").tag(Optional<NotesLibrary.MeetingFile>.none)
                    Divider()
                    ForEach(NotesLibrary.meetingsByDay(limit: 15), id: \.day) { group in
                        Section(header: Text(group.day)) {
                            ForEach(group.meetings) { meeting in
                                Text(meeting.time).tag(Optional(meeting))
                            }
                        }
                    }
                }
                .labelsHidden()
                Button {
                    if let url = selected?.url { NotesViewerWindowController.present(fileURL: url) }
                } label: {
                    Image(systemName: "arrow.up.forward.square")
                }
                .buttonStyle(.borderless)
                .disabled(selected == nil)
                .help("Open this meeting's notes file")
            }
            .padding(.horizontal, 16)

            HStack {
                TextField("What did we decide about…?", text: $question)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(ask)
                Button(action: ask) {
                    if isAsking {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Ask")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isAsking || question.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 16)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundColor(.red)
            }

            ScrollView {
                if answer.isEmpty && !isAsking {
                    Text(selected == nil
                         ? "Searches every meeting for lines related to your question and answers from those excerpts, citing which meeting — only the matching excerpts are sent to Groq."
                         : "Answers are grounded in the selected meeting's transcript — nothing leaves your Mac except the transcript sent to Groq for this question.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding()
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(answer)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if !sources.isEmpty {
                            Divider()
                            Text("Sources")
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.secondary)
                            ForEach(sources) { source in
                                Button {
                                    NotesViewerWindowController.present(fileURL: source.url)
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "doc.text")
                                        Text(source.displayName)
                                        Image(systemName: "arrow.up.forward.square")
                                            .foregroundColor(.secondary)
                                    }
                                    .font(.caption)
                                }
                                .buttonStyle(.plain)
                                .help("Open this meeting's notes file")
                            }
                        }
                    }
                    .padding()
                }
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .onAppear {
            meetings = NotesLibrary.meetingFiles(limit: 15)
        }
    }

    private func ask() {
        let q = question.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }

        isAsking = true
        errorMessage = nil
        answer = ""
        sources = []
        let meeting = selected
        Task {
            do {
                let result: String
                var usedSources: [NotesLibrary.MeetingFile] = []
                if let meeting,
                   let transcript = try? String(contentsOf: meeting.url, encoding: .utf8) {
                    result = try await polisher.answer(question: q, transcript: transcript)
                    usedSources = [meeting]
                } else {
                    // All meetings: expand the question into search terms,
                    // retrieve matching excerpts, answer from those.
                    let terms = await polisher.searchTerms(for: q)
                    let retrieved = NotesLibrary.excerpts(matching: terms)
                    if retrieved.text.isEmpty {
                        result = "No meeting content matched this question (searched terms: \(terms.joined(separator: ", "))). Try rewording, or pick a specific meeting."
                    } else {
                        result = try await polisher.answerAcrossMeetings(question: q, excerpts: retrieved.text)
                        usedSources = retrieved.sources
                    }
                }
                await MainActor.run { answer = result; sources = usedSources; isAsking = false }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isAsking = false
                }
            }
        }
    }
}

// MARK: - Action Items

private struct ActionItemsTab: View {
    @State private var groups: [NotesLibrary.MeetingActionItems] = []

    var body: some View {
        Group {
            if groups.isEmpty {
                VStack {
                    Spacer()
                    Text("No action items found in the last \(AppSettings.shared.actionItemsLookback) meetings.")
                        .foregroundColor(.secondary)
                    Text("Action items are collected from the AI summary appended when a meeting ends.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else {
                List {
                    ForEach(groups) { group in
                        Section {
                            ForEach(group.items) { item in
                                Button {
                                    toggle(item)
                                } label: {
                                    HStack(alignment: .top, spacing: 8) {
                                        Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                                            .foregroundColor(item.done ? .secondary : .accentColor)
                                        Text(item.text)
                                            .strikethrough(item.done)
                                            .foregroundColor(item.done ? .secondary : .primary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help(item.done ? "Click to mark as open" : "Click to mark as done")
                            }
                        } header: {
                            Button {
                                NotesViewerWindowController.present(fileURL: group.file.url)
                            } label: {
                                HStack(spacing: 4) {
                                    Text(group.file.displayName)
                                        .font(.subheadline.weight(.semibold))
                                    Image(systemName: "arrow.up.forward.square")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            .help("Open this meeting's notes file")
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .onAppear { groups = NotesLibrary.actionItemsByMeeting() }
    }

    /// Flip the checkbox in the file, then reload so the UI matches the file.
    private func toggle(_ item: NotesLibrary.ActionItem) {
        NotesLibrary.toggleDone(item)
        groups = NotesLibrary.actionItemsByMeeting()
    }
}
