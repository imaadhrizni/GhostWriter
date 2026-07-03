import SwiftUI
import AppKit

// MARK: - Notes Assistant
//
// One window, three tools over the meeting-notes folder:
//   Search       — full-text search across every notes file
//   Ask          — Q&A over one meeting's transcript via the polishing model
//   Action Items — aggregated "## Action Items" sections from recent meetings

final class NotesAssistantWindowController: NSWindowController {
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
        window.contentView = NSHostingView(rootView: NotesAssistantView())
    }

    func showAndActivate() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
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
    static func search(_ query: String, maxHits: Int = 60, maxFiles: Int = 200) async -> [SearchHit] {
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

    struct ActionItem: Identifiable {
        let id = UUID()
        let file: MeetingFile
        let text: String
    }

    /// Bullets under "## Action Items" headings, newest meetings first.
    static func actionItems(fromLast meetings: Int = 10) -> [ActionItem] {
        var items: [ActionItem] = []
        for file in meetingFiles(limit: meetings) {
            guard let content = try? String(contentsOf: file.url, encoding: .utf8) else { continue }
            var inSection = false
            for rawLine in content.split(whereSeparator: \.isNewline) {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                if line.lowercased().hasPrefix("## action items") { inSection = true; continue }
                if inSection {
                    if line.hasPrefix("#") { inSection = false; continue }
                    if line.hasPrefix("-") || line.hasPrefix("*") {
                        let text = line.dropFirst().trimmingCharacters(in: .whitespaces)
                        if !text.isEmpty { items.append(ActionItem(file: file, text: text)) }
                    }
                }
            }
        }
        return items
    }
}

// MARK: - Root view

private enum AssistantMode: String, CaseIterable, Identifiable {
    case search = "Search", ask = "Ask", actions = "Action Items"
    var id: String { rawValue }
}

struct NotesAssistantView: View {
    @State private var mode: AssistantMode = .search

    var body: some View {
        VStack(spacing: 12) {
            Picker("", selection: $mode) {
                ForEach(AssistantMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.top, 12)

            switch mode {
            case .search:  SearchTab()
            case .ask:     AskTab()
            case .actions: ActionItemsTab()
            }
        }
        .frame(minWidth: 560, minHeight: 420)
    }
}

// MARK: - Search

private struct SearchTab: View {
    @State private var query = ""
    @State private var hits: [NotesLibrary.SearchHit] = []
    @State private var searchTask: Task<Void, Never>?

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
                List(hits) { hit in
                    Button {
                        NSWorkspace.shared.open(hit.file.url)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(hit.line)
                                .lineLimit(2)
                            Text(hit.file.displayName)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
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
    @State private var isAsking = false
    @State private var errorMessage: String?

    private let polisher = TextPolisher()

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Meeting")
                Picker("", selection: $selected) {
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
                    if let url = selected?.url { NSWorkspace.shared.open(url) }
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
                .disabled(isAsking || selected == nil || question.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 16)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundColor(.red)
            }

            ScrollView {
                if answer.isEmpty && !isAsking {
                    Text("Answers are grounded in the selected meeting's transcript — nothing leaves your Mac except the transcript sent to Groq for this question.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding()
                } else {
                    Text(answer)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .onAppear {
            meetings = NotesLibrary.meetingFiles(limit: 15)
            if selected == nil { selected = meetings.first }
        }
    }

    private func ask() {
        guard let meeting = selected,
              let transcript = try? String(contentsOf: meeting.url, encoding: .utf8) else { return }
        let q = question.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }

        isAsking = true
        errorMessage = nil
        answer = ""
        Task {
            do {
                let result = try await polisher.answer(question: q, transcript: transcript)
                await MainActor.run { answer = result; isAsking = false }
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
    @State private var items: [NotesLibrary.ActionItem] = []

    var body: some View {
        Group {
            if items.isEmpty {
                VStack {
                    Spacer()
                    Text("No action items found in the last 10 meetings.")
                        .foregroundColor(.secondary)
                    Text("Action items are collected from the AI summary appended when a meeting ends.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else {
                List(items) { item in
                    Button {
                        NSWorkspace.shared.open(item.file.url)
                    } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "checkmark.circle")
                                .foregroundColor(.accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.text)
                                Text(item.file.displayName)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.inset)
            }
        }
        .onAppear { items = NotesLibrary.actionItems() }
    }
}
