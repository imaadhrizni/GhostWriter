import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Catalog · Open Questions

struct OpenQuestionsList: View {
    @ObservedObject var store: CatalogStore
    @State private var items: [QItem] = []
    @State private var loading = false
    @State private var query = ""
    @State private var fKind = ""   // "", "org", "project"
    @State private var fID = ""
    @State private var fRange: DateRange = DateRange.defaultRange
    // Open Year/Month/Day groups.
    @State private var expanded: Set<String> = []
    // Include answered (ticked-off) questions in the list.
    @State private var showAnswered = false

    struct QItem: Identifiable {
        let id = UUID()
        let question: String
        let title: String
        let date: Date?
        let url: URL
        let orgIDs: Set<String>
        let projIDs: Set<String>
        var done: Bool
        var rawLine: String
    }

    // A note and its unanswered questions, inside an account/project group.
    struct NoteGroup: Identifiable {
        let url: URL
        var id: URL { url }
        let title: String
        let date: Date?
        var questions: [QItem]
    }
    private var filtered: [QItem] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return items.filter { item in
            (showAnswered || !item.done)
            && (q.isEmpty || item.question.lowercased().contains(q) || item.title.lowercased().contains(q))
            && (fKind != "org" || item.orgIDs.contains(fID))
            && (fKind != "project" || item.projIDs.contains(fID))
            && fRange.includes(item.date)
        }
    }

    /// Open (not-yet-answered) questions among the currently filtered set.
    private var openCount: Int { filtered.filter { !$0.done }.count }

    /// The filtered questions collapsed into one entry per note (newest-first).
    private var noteGroups: [NoteGroup] {
        var order: [URL] = []
        var byURL: [URL: NoteGroup] = [:]
        for q in filtered {
            if let existing = byURL[q.url] {
                var ng = existing; ng.questions.append(q); byURL[q.url] = ng
            } else {
                byURL[q.url] = NoteGroup(url: q.url, title: q.title, date: q.date, questions: [q])
                order.append(q.url)
            }
        }
        return order.compactMap { byURL[$0] }
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    /// Notes grouped into the shared Year → Month → Day tree.
    private var tree: [DateGroupNode<NoteGroup>] {
        DateGrouping.tree(noteGroups) { $0.date }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                if loading && items.isEmpty {
                    ProgressView("Scanning notes…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if filtered.isEmpty {
                    ContentUnavailableView("No open questions", systemImage: "checkmark.circle",
                        description: Text("Questions collect here from meeting notes that have an “Open Questions” section (enable AI Extraction in Settings → Meetings)."))
                } else {
                    List {
                        DateGroupDisclosure(nodes: tree, expanded: $expanded) { ng in
                            VStack(alignment: .leading, spacing: 2) {
                                noteHeader(ng)
                                ForEach(ng.questions) { q in questionRow(q) }
                            }
                        }
                    }
                    .onChange(of: tree.map(\.id)) { _, _ in
                        if expanded.isEmpty { expanded = DateGrouping.defaultExpanded(tree) }
                    }
                    .onAppear { if expanded.isEmpty { expanded = DateGrouping.defaultExpanded(tree) } }
                }
            }
        }
        .task { await scan() }
    }

    /// A note's row inside a group — click to open the note; shows its date and
    /// how many questions it holds.
    private func noteHeader(_ ng: NoteGroup) -> some View {
        Button { NotesViewerWindowController.present(fileURL: ng.url) } label: {
            HStack(spacing: 6) {
                Image(systemName: "doc.text").font(.caption2).foregroundStyle(.secondary)
                Text(ng.title).font(.subheadline.weight(.medium)).lineLimit(1)
                if let d = ng.date {
                    Text(d.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                let open = ng.questions.filter { !$0.done }.count
                Text(open == ng.questions.count ? "\(open) open" : "\(open) open · \(ng.questions.count - open) answered")
                    .font(.caption2).foregroundStyle(.secondary)
                Image(systemName: "arrow.up.forward.square").font(.caption2).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
    }

    /// A single question, indented under its note. The leading checkbox ticks
    /// it answered (or back to open); tapping the text opens the source note.
    private func questionRow(_ q: QItem) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Button { toggle(q) } label: {
                Image(systemName: q.done ? "checkmark.circle.fill" : "circle")
                    .font(.caption).foregroundStyle(q.done ? .green : .orange).padding(.top, 2)
            }
            .buttonStyle(.plain)
            .help(q.done ? "Mark as unanswered" : "Mark as answered")
            Text(q.question)
                .lineLimit(4)
                .strikethrough(q.done, color: .secondary)
                .foregroundStyle(q.done ? .secondary : .primary)
            Spacer(minLength: 0)
        }
        .padding(.leading, 8)
        .contentShape(Rectangle())
        .onTapGesture { NotesViewerWindowController.present(fileURL: q.url) }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("\(openCount) open").font(.headline)
            Spacer()
            EntitySearchBar(text: $query, placeholder: "Search questions").frame(width: 160)
            Toggle("Answered", isOn: $showAnswered)
                .toggleStyle(.button).font(.caption)
                .help("Show questions already marked answered")
            RangePicker(range: $fRange, compact: true)
            OrgProjectTreePicker(store: store, kind: $fKind, id: $fID, allLabel: "All accounts")
            if !filtered.isEmpty {
                ExpandCollapseButton(tree: tree, expanded: $expanded)
                    .buttonStyle(.borderless).labelStyle(.iconOnly)
            }
            Button { Task { await scan() } } label: { Image(systemName: "arrow.clockwise") }
                .help("Rescan notes")
        }
        .padding(8)
    }


    private func scan() async {
        loading = true
        defer { loading = false }
        var result: [QItem] = []
        for f in NotesLibrary.meetingFiles(limit: AppSettings.shared.searchDepth) {
            guard let text = f.url.readText() else { continue }
            let qs = NotesLibrary.openQuestions(in: text)
            guard !qs.isEmpty else { continue }
            let title = FrontMatter.title(in: text) ?? f.displayName
            let rel = AppSettings.shared.relativePath(of: f.url)
            let note = store.doc.notes.first { $0.filePath == rel }
            let orgIDs = Set(note.map { store.effectiveOrgIDs(of: $0) } ?? [])
            let projIDs = note.map { store.effectiveProjectIDs(of: $0) } ?? []
            let date = DateDisplay.posixDay.date(from: f.day)
            for q in qs {
                result.append(QItem(question: q.text, title: title, date: date, url: f.url,
                                    orgIDs: orgIDs, projIDs: projIDs, done: q.done, rawLine: q.rawLine))
            }
        }
        items = result
    }

    /// Tick a question answered (or back to open) — rewrites its checkbox in the
    /// source note, then updates the row in place (no full rescan).
    private func toggle(_ q: QItem) {
        guard let i = items.firstIndex(where: { $0.id == q.id }) else { return }
        let nowDone = !items[i].done
        NotesLibrary.setCheckbox(rawLine: items[i].rawLine, text: items[i].question,
                                 done: nowDone, inFile: items[i].url)
        items[i].done = nowDone
        items[i].rawLine = "- [\(nowDone ? "x" : " ")] \(items[i].question)"
    }
}

// MARK: POC Tracker (master list)

/// How a project's POC stands, derived from its criteria. Drives the tracker's
/// status filter, grouping, and per-row badge/tint.
