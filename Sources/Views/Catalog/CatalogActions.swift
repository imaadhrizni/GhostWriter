import SwiftUI
import AppKit

// MARK: - Catalog · Action Items
//
// One place to see every action item from your meeting notes, with filters. It
// builds on the same data the Digest and the dashboard use (`NotesLibrary`
// parsing and one shared due-date parser), so "overdue" means the same thing
// everywhere — and "tomorrow" in a note is resolved against the day of *that*
// meeting. Tick an item here and the checkbox in its note is updated.
//
// The what-to-show logic (status, owner, scope, range, search, grouping, counts)
// lives in `ActionQuery`; this file is the scan and the SwiftUI.

struct ActionItemsList: View {
    @ObservedObject var store: CatalogStore
    @ObservedObject private var settings = AppSettings.shared

    /// An item with the parsed note line it came from (needed to tick it in place).
    struct Row: Identifiable {
        var entry: ActionEntry
        var item: NotesLibrary.ActionItem
        var url: URL { item.file.url }
        var id: UUID { entry.id }
    }

    /// Who to show items for — the owner menu's choices.
    enum OwnerChoice: Hashable {
        case anyone, me, unassigned
        case named(String)
    }

    /// A "mark these done / open" request — a group, a meeting, an owner, or everything shown.
    struct BulkChange: Identifiable {
        let id = UUID()
        let title: String
        let ids: [UUID]
        let done: Bool
    }

    @State private var rows: [Row] = []
    @State private var loading = false
    @State private var filter = ActionFilter()
    @State private var grouping: ActionGrouping = .due
    @State private var sort: ActionSort = .due
    @State private var ascending = true
    @State private var ownerChoice: OwnerChoice = .anyone
    @State private var range: DateRange = .quarter
    @State private var scopeKind = ""
    @State private var scopeID = ""
    /// What the notice's Undo reverts: these rows were set to `done`'s opposite.
    @State private var undo: (ids: [UUID], done: Bool)?
    /// A bulk change waiting for confirmation (several notes get rewritten).
    @State private var pendingBulk: BulkChange?
    @State private var message: String?
    @State private var confirmReminders = false

    // MARK: Derived

    /// The filter with the view's own controls folded in.
    private var activeFilter: ActionFilter {
        var f = filter
        f.scopeKind = scopeKind
        f.scopeID = scopeID
        f.meetingWithinDays = range.days
        switch ownerChoice {
        case .anyone:      f.owners = nil
        case .me:          f.owners = Set(settings.myOwnerNames)
        case .unassigned:  f.owners = [ActionFilter.unassigned]
        case .named(let n): f.owners = [n]
        }
        return f
    }

    private var entries: [ActionEntry] { rows.map(\.entry) }
    private var shown: [ActionEntry] { ActionQuery.apply(entries, activeFilter) }
    private var sections: [ActionQuery.Section] { ActionQuery.group(shown, by: grouping, sort: sort, ascending: ascending) }
    private var counts: ActionQuery.Counts { ActionQuery.counts(entries, activeFilter) }
    private var rowByID: [UUID: Row] { Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }) }
    private var isDefaultView: Bool {
        filter.status == .open && filter.query.isEmpty && ownerChoice == .anyone
            && scopeKind.isEmpty && range == .quarter && grouping == .due
            && sort == .due && ascending
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let message { notice(message) }
            Group {
                if loading && rows.isEmpty {
                    ProgressView("Scanning notes…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if rows.isEmpty {
                    ContentUnavailableView("No action items yet", systemImage: "checklist",
                        description: Text("Action items collect here from meeting notes that have an “Action Items” section (enable AI Extraction in Settings → Meetings)."))
                } else if shown.isEmpty {
                    ContentUnavailableView {
                        Label("Nothing matches", systemImage: "line.3.horizontal.decrease.circle")
                    } description: {
                        Text("No action items fit these filters.")
                    } actions: {
                        Button("Clear filters") { resetFilters() }
                    }
                } else {
                    List {
                        ForEach(sections) { section in
                            Section {
                                ForEach(section.entries) { e in
                                    if let row = rowByID[e.id] { rowView(row) }
                                }
                            } header: { sectionHeader(section) }
                        }
                    }
                    .listStyle(.inset)
                }
            }
        }
        .task { await scan() }
        .confirmationDialog(pendingBulk.map { "\($0.done ? "Mark" : "Reopen") \($0.ids.count) item\($0.ids.count == 1 ? "" : "s") \($0.done ? "done" : "as open")?" } ?? "",
                            isPresented: Binding(get: { pendingBulk != nil }, set: { if !$0 { pendingBulk = nil } }),
                            titleVisibility: .visible) {
            if let b = pendingBulk {
                Button(b.done ? "Mark Done" : "Reopen") { setDone(b.ids, done: b.done); pendingBulk = nil }
            }
            Button("Cancel", role: .cancel) { pendingBulk = nil }
        } message: {
            Text(pendingBulk.map { "\($0.title). Each item's checkbox is rewritten in its source note; you can undo right after." } ?? "")
        }
        .confirmationDialog("Add \(remindable.count) open item\(remindable.count == 1 ? "" : "s") to Reminders?",
                            isPresented: $confirmReminders, titleVisibility: .visible) {
            Button("Add to Reminders") { addToReminders(remindable) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Creates a reminder in your default list for each open item shown, with its due date when one is known.")
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("\(counts.open) open").font(.headline)
                if counts.overdue > 0 {
                    TintedPill(text: "\(counts.overdue) overdue", tint: .red, weight: .semibold, opacity: 0.16, hPad: 7, vPad: 2)
                }
                if counts.dueSoon > 0 {
                    TintedPill(text: "\(counts.dueSoon) due soon", tint: .orange, weight: .semibold, opacity: 0.16, hPad: 7, vPad: 2)
                }
                Spacer()
                EntitySearchBar(text: $filter.query, placeholder: "Search action items").frame(width: 190)
                Button { Task { await scan() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Rescan notes")
            }
            FlowLayout(spacing: 8) {
                labeled("Show") {
                    Picker("Show", selection: $filter.status) {
                        ForEach(ActionStatus.allCases) { s in Text("\(s.rawValue) (\(counts.count(s)))").tag(s) }
                    }
                    .pickerStyle(.menu).labelsHidden().fixedSize().help("Which items to list")
                }

                ownerMenu

                labeled("Group by") {
                    Picker("Group by", selection: $grouping) {
                        ForEach(ActionGrouping.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.menu).labelsHidden().fixedSize().help("How to group the list")
                }

                labeled("Sort by") {
                    HStack(spacing: 4) {
                        Picker("Sort by", selection: $sort) {
                            ForEach(ActionSort.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.menu).labelsHidden().fixedSize()
                        Button { ascending.toggle() } label: {
                            Image(systemName: ascending ? "arrow.up" : "arrow.down")
                        }
                        .buttonStyle(.borderless)
                        .help(sort.label(ascending: ascending) + " — click to reverse")
                    }
                    .help("Order of items inside each group")
                }

                RangePicker(range: $range, compact: true)
                    .help("Only items from meetings in this window")
                OrgProjectTreePicker(store: store, kind: $scopeKind, id: $scopeID, allLabel: "All accounts")

                Menu {
                    Button("Mark All Shown as Done (\(remindable.count))") { requestBulk("All \(remindable.count) open items shown", remindable.map(\.id), done: true) }
                        .disabled(remindable.isEmpty)
                    Button("Reopen All Shown Done Items (\(doneShown.count))") { requestBulk("All \(doneShown.count) completed items shown", doneShown, done: false) }
                        .disabled(doneShown.isEmpty)
                    Divider()
                    Button("Copy Shown as Checklist") { copyChecklist(shown.map(\.id)) }
                } label: { Label("Bulk", systemImage: "checkmark.circle.badge.questionmark") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help("Act on everything shown — or use a group's ⋯ menu for just that group")

                Button { confirmReminders = true } label: { Label("Reminders", systemImage: "bell") }
                    .disabled(remindable.isEmpty)
                    .help("Add the open items shown to Apple Reminders")
                Button { DigestWindowController.present() } label: { Label("Digest", systemImage: "newspaper") }
                    .help("Open the Proactive Digest — the same open and overdue items, as a rollup")
                if !isDefaultView {
                    Button("Reset") { resetFilters() }.help("Back to open items, last 90 days, grouped by due date")
                }
            }
            .controlSize(.small)
        }
        .padding(10)
    }

    /// A small secondary caption beside a control, so inline labels sit at the same
    /// size as the menus they name.
    private func labeled<C: View>(_ title: String, @ViewBuilder _ control: () -> C) -> some View {
        HStack(spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            control()
        }
    }

    private var ownerMenu: some View {
        let owners = ActionQuery.owners(in: entries)
        let mine = Set(settings.myOwnerNames.map { $0.lowercased() })
        let others = owners.filter { !mine.contains($0.name.lowercased()) }
        return Menu {
            choiceButton("Anyone", .anyone)
            choiceButton("Me", .me)
            choiceButton("Unassigned", .unassigned)
            if !others.isEmpty {
                Divider()
                ForEach(others.prefix(40), id: \.name) { o in choiceButton("\(o.name) (\(o.count))", .named(o.name)) }
            }
        } label: {
            Label(ownerLabel, systemImage: "person.crop.circle")
        }
        .menuStyle(.borderlessButton).fixedSize().help("Whose items to show")
    }

    private func choiceButton(_ title: String, _ choice: OwnerChoice) -> some View {
        Button { ownerChoice = choice } label: {
            if ownerChoice == choice { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }

    private var ownerLabel: String {
        switch ownerChoice {
        case .anyone: return "Anyone"
        case .me: return "Me"
        case .unassigned: return "Unassigned"
        case .named(let n): return n
        }
    }

    private func notice(_ text: String) -> some View {
        HStack(spacing: 8) {
            Text(text).font(.caption)
            if let u = undo { Button("Undo") { setDone(u.ids, done: !u.done, recordUndo: false); message = "Undone."; undo = nil }.buttonStyle(.link).font(.caption) }
            Spacer()
            Button { message = nil; undo = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless).font(.caption)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Color.accentColor.opacity(0.10))
    }

    // MARK: Sections & rows

    private func sectionHeader(_ s: ActionQuery.Section) -> some View {
        HStack(spacing: 6) {
            Text(s.title).font(.subheadline.weight(.semibold))
                .foregroundStyle(s.id == "due-0" ? Color.red : Color.primary)
            if let sub = s.subtitle { Text(sub).font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Text("\(s.entries.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            groupMenu(s)
        }
    }

    /// The ⋯ menu on a group: finish, reopen, remind, or copy just that group.
    private func groupMenu(_ s: ActionQuery.Section) -> some View {
        let open = s.entries.filter { !$0.done }.map(\.id)
        let done = s.entries.filter(\.done).map(\.id)
        return Menu {
            Button("Mark \(open.count) Open as Done") { requestBulk("Every open item in “\(s.title)”", open, done: true) }
                .disabled(open.isEmpty)
            Button("Reopen \(done.count) Done") { requestBulk("Every completed item in “\(s.title)”", done, done: false) }
                .disabled(done.isEmpty)
            Divider()
            Button("Add Open Items to Reminders") { addToReminders(open.compactMap { rowByID[$0] }) }.disabled(open.isEmpty)
            Button("Copy as Checklist") { copyChecklist(s.entries.map(\.id)) }
        } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Actions for this group")
    }

    private func rowView(_ row: Row) -> some View {
        let e = row.entry
        let today = Calendar.current.startOfDay(for: Date())
        let bucket = ActionQuery.bucket(of: e, today: today)
        return HStack(alignment: .top, spacing: 8) {
            Button { toggle(row.id) } label: {
                Image(systemName: e.done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(e.done ? .green : (bucket == .overdue ? .red : .secondary))
            }
            .buttonStyle(.plain)
            .help(e.done ? "Mark as not done" : "Mark as done — updates the note")

            VStack(alignment: .leading, spacing: 4) {
                Text(e.text)
                    .strikethrough(e.done, color: .secondary)
                    .foregroundStyle(e.done ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                FlowLayout(spacing: 6) {
                    if let o = e.owner {
                        TintedPill(text: "@\(o)", tint: isMe(o) ? .green : .blue, weight: .regular, opacity: 0.15)
                    }
                    if let label = dueLabel(e) {
                        TintedPill(text: label, tint: dueTint(bucket), weight: .regular, opacity: 0.15)
                    }
                    if e.account != "Unfiled" {
                        TintedPill(text: e.project.map { "\(e.account) › \($0)" } ?? e.account, tint: .gray, weight: .regular, opacity: 0.14)
                    }
                    Button { NotesViewerWindowController.present(fileURL: row.url) } label: {
                        Text(noteLabel(e)).font(.caption2).foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain).help("Open the meeting note")
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button(e.done ? "Mark as Not Done" : "Mark as Done") { toggle(row.id) }
            Button("Open Note") { NotesViewerWindowController.present(fileURL: row.url) }
            Button("Copy") { Clipboard.plain(e.text) }
            if !e.done { Button("Add to Reminders") { addToReminders([row]) } }
            let sameNote = shown.filter { $0.noteKey == e.noteKey && !$0.done }.map(\.id)
            let sameOwner = e.owner.map { o in shown.filter { $0.owner?.caseInsensitiveCompare(o) == .orderedSame && !$0.done }.map(\.id) } ?? []
            if sameNote.count > 1 || sameOwner.count > 1 { Divider() }
            if sameNote.count > 1 {
                Button("Mark All \(sameNote.count) from This Meeting as Done") { requestBulk("Open items shown from “\(e.noteTitle)”", sameNote, done: true) }
            }
            if sameOwner.count > 1, let o = e.owner {
                Button("Mark All \(sameOwner.count) for @\(o) as Done") { requestBulk("Open items shown for @\(o)", sameOwner, done: true) }
            }
        }
    }

    private func isMe(_ owner: String) -> Bool { settings.myOwnerNames.contains { $0.caseInsensitiveCompare(owner) == .orderedSame } }

    private func noteLabel(_ e: ActionEntry) -> String {
        [e.noteTitle, e.noteDate.map { $0.formatted(date: .abbreviated, time: .omitted) }].compactMap { $0 }.joined(separator: " · ")
    }

    /// "due tomorrow · Thu 6 Nov" — the words the note used, plus the day they were resolved to.
    private func dueLabel(_ e: ActionEntry) -> String? {
        guard let text = e.dueText else { return nil }
        guard let due = e.due else { return "due \(text)" }
        let day = due.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        let isDate = text.first?.isNumber == true && !text.lowercased().contains("week") && !text.lowercased().contains("month")
        return isDate ? "due \(day)" : "due \(text) · \(day)"
    }

    private func dueTint(_ b: ActionBucket) -> Color {
        switch b { case .overdue: return .red; case .today, .thisWeek: return .orange; default: return .secondary }
    }

    // MARK: Actions

    private func resetFilters() {
        filter = ActionFilter(); ownerChoice = .anyone; scopeKind = ""; scopeID = ""; range = .quarter; grouping = .due; sort = .due; ascending = true
    }

    /// Open, shown items — what "Add to Reminders" would create.
    private var remindable: [Row] {
        let byID = rowByID
        return shown.filter { !$0.done }.compactMap { byID[$0.id] }
    }

    private func addToReminders(_ list: [Row]) {
        let items = list.map(\.item)
        Task {
            do {
                let n = try await RemindersExporter.export(items)
                message = "Added \(n) reminder\(n == 1 ? "" : "s") to Reminders."
            } catch {
                message = error.localizedDescription
            }
            undo = nil
        }
    }

    /// Ids of completed items currently shown.
    private var doneShown: [UUID] { shown.filter(\.done).map(\.id) }

    /// Flip one item.
    private func toggle(_ id: UUID) {
        guard let row = rowByID[id] else { return }
        setDone([id], done: !row.entry.done)
    }

    /// One item goes straight through; several ask first.
    private func requestBulk(_ title: String, _ ids: [UUID], done: Bool) {
        if ids.count <= 1 { setDone(ids, done: done) } else { pendingBulk = BulkChange(title: title, ids: ids, done: done) }
    }

    /// Set the given items done (or open): rewrites each checkbox in its source
    /// note, then updates the rows in place — no rescan. Items already in the
    /// target state are skipped; a failed rewrite (the note changed since the scan)
    /// is counted and reported rather than aborting the rest.
    private func setDone(_ ids: [UUID], done: Bool, recordUndo: Bool = true) {
        var changed: [UUID] = [], failed = 0
        for id in ids {
            guard let i = rows.firstIndex(where: { $0.id == id }), rows[i].entry.done != done else { continue }
            let item = rows[i].item
            guard NotesLibrary.toggleDone(item) else { failed += 1; continue }
            let bullet = item.rawLine.hasPrefix("*") ? "*" : "-"
            rows[i].item = NotesLibrary.ActionItem(file: item.file, text: item.text, done: done,
                                                   rawLine: "\(bullet) [\(done ? "x" : " ")] \(item.text)")
            rows[i].entry.done = done
            changed.append(id)
        }
        var text: String
        switch (changed.count, done) {
        case (1, true):  text = "Marked done in “\(rows.first { $0.id == changed[0] }?.entry.noteTitle ?? "note")”."
        case (1, false): text = "Marked open again."
        case (let n, _): text = n == 0 ? "Nothing to change." : "\(done ? "Marked" : "Reopened") \(n) items\(done ? " done" : "")."
        }
        if failed > 0 { text += " \(failed) couldn't be updated — rescan and try again." }
        message = text
        undo = (recordUndo && !changed.isEmpty) ? (changed, done) : nil
    }

    /// The items as a Markdown checklist, ready to paste into notes or chat.
    private func copyChecklist(_ ids: [UUID]) {
        let byID = rowByID
        let lines = ids.compactMap { byID[$0] }.map { r -> String in
            var line = "- [\(r.entry.done ? "x" : " ")] \(r.entry.text)"
            if let o = r.entry.owner { line += " — @\(o)" }
            if let d = r.entry.dueText { line += " (due: \(d))" }
            return line
        }
        Clipboard.plain(lines.joined(separator: "\n"))
        message = "Copied \(lines.count) item\(lines.count == 1 ? "" : "s") as a checklist."
        undo = nil
    }

    // MARK: Scan

    private struct Parsed: Sendable {
        let file: NotesLibrary.MeetingFile
        let title: String
        let items: [NotesLibrary.ActionItem]
    }

    private func scan() async {
        loading = true
        defer { loading = false }
        let files = NotesLibrary.meetingFiles(limit: settings.searchDepth)
        // Reading hundreds of notes shouldn't hold up the window.
        let parsed: [Parsed] = await Task.detached(priority: .userInitiated) {
            files.compactMap { f -> Parsed? in
                guard let text = f.url.readText() else { return nil }
                let items = NotesLibrary.actionItems(in: text, file: f)
                guard !items.isEmpty else { return nil }
                return Parsed(file: f, title: FrontMatter.title(in: text) ?? f.displayName, items: items)
            }
        }.value

        let notesByPath = Dictionary(store.doc.notes.map { ($0.filePath, $0) }, uniquingKeysWith: { a, _ in a })
        var result: [Row] = []
        for p in parsed {
            let note = notesByPath[settings.relativePath(of: p.file.url)]
            let orgIDs = note.map { store.effectiveOrgIDs(of: $0) } ?? []
            let projIDs = note.map { store.effectiveProjectIDs(of: $0) } ?? []
            let project = note?.projectIDs.first.flatMap { store.project($0) }
            let org = project.flatMap { store.org(forProject: $0.id) } ?? note?.orgIDs.first.flatMap { store.org($0) }
            let date = DateDisplay.posixDay.date(from: p.file.day)
            for item in p.items {
                let entry = ActionEntry(
                    id: UUID(), text: item.displayText, owner: item.owner, dueText: item.due, due: item.dueDate,
                    done: item.done, noteKey: p.file.url.path, noteTitle: p.title, noteDate: date,
                    account: org?.name ?? "Unfiled", project: project?.name, orgIDs: orgIDs, projIDs: projIDs)
                result.append(Row(entry: entry, item: item))
            }
        }
        rows = result
    }
}
