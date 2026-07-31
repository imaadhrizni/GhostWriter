import SwiftUI

// MARK: - Meeting Notes

struct MeetingNotesPane: View {
    @ObservedObject private var settings = AppSettings.shared
    /// Files held in the semantic search index, shown next to Rebuild.
    @State private var indexedCount = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsGroup("Files") {
                HStack {
                    Text("Save to")
                    Spacer()
                    Text(settings.notesFolder.path.abbreviatingHome())
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Choose…") { pickNotesFolder() }
                }
                Divider()
                HStack {
                    Text("Organize files")
                    Spacer()
                    Picker("", selection: $settings.notesOrganization) {
                        ForEach(NotesOrganization.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }
                Text("New meetings are saved into dated subfolders so the notes folder stays tidy. Existing files stay where they are — history, search, and stats find them either way.")
                    .font(.caption).foregroundColor(.secondary)
                Divider()
                Toggle("Obsidian/Notion front-matter", isOn: $settings.frontMatterEnabled)
                Text("Prepends YAML metadata (title, date, tags) to each notes file.")
                    .font(.caption).foregroundColor(.secondary)
            }

            SettingsGroup("Recording") {
                Toggle("Retain meeting audio", isOn: $settings.retainMeetingAudio)
                Text("Saves a compressed recording of each meeting under a “Audio” folder beside your notes, so a note whose transcription failed can be regenerated from the audio (Catalog → the note → Recording). Delete recordings any time from there. Audio is otherwise never written to disk.")
                    .font(.caption).foregroundColor(.secondary)
            }

            SettingsGroup("Summary Content") {
                Toggle("Append AI summary when a meeting ends", isOn: $settings.summariesEnabled)
                Text("Adds the template's sections to the notes file.")
                    .font(.caption).foregroundColor(.secondary)
                Divider()
                Toggle("Append action items", isOn: $settings.actionItemsEnabled)
                Text("Adds an Action Items checklist (with owners when identifiable). Shown per note in the Catalog, with export to Reminders.")
                    .font(.caption).foregroundColor(.secondary)
            }

            SettingsGroup("AI Extraction") {
                Text("Extra passes that enrich the summary. Each needs network access and is skipped in Local-only mode.")
                    .font(.caption).foregroundColor(.secondary)
                Divider()
                Toggle("Extract decisions & risks", isOn: $settings.structuredExtraction)
                Text("Adds Decisions and Risks & Blockers sections to the summary. (Open Questions has its own toggle below.)")
                    .font(.caption).foregroundColor(.secondary)
                Divider()
                Toggle("Extract key fields per meeting type", isOn: $settings.extractKeyFields)
                Text("Pulls the fields that matter for the chosen template — a customer call's deal stage, budget, timeline, and next step; an interview's recommendation; a 1:1's sentiment — into a Key Details section and machine-readable front-matter. Categorical fields (deal stage, recommendation, sentiment) are mirrored into tags so you can filter by them in the Catalog.")
                    .font(.caption).foregroundColor(.secondary)
                Divider()
                Toggle("Extract unanswered questions", isOn: $settings.extractUnanswered)
                Text("Fills the note's Open Questions section — questions raised in the meeting that never got a clear answer, i.e. your follow-up list — as tickable checkboxes you can mark answered in the Catalog. Merges with the summary's own Open Questions if that's enabled. One extra AI call.")
                    .font(.caption).foregroundColor(.secondary)
                Divider()
                Toggle("Add topic chapters", isOn: $settings.topicChapters)
                Text("Appends a timestamped jump-list segmenting the meeting into topics. One extra AI call per meeting.")
                    .font(.caption).foregroundColor(.secondary)
                Divider()
                Toggle("Add talk-time analytics", isOn: $settings.talkTimeAnalytics)
                Text("Appends a local engagement readout — per-speaker talk share, turns, questions, longest monologue, and whether next steps were captured. Computed on-device from the transcript; no AI call.")
                    .font(.caption).foregroundColor(.secondary)
                Divider()
                Toggle("Extract objections & competitors", isOn: $settings.objectionIntel)
                Text("Appends an Objections & Competitors section — the concerns and pushback the customer raised (with any response given) and any competing or incumbent tools mentioned, each with context. One extra AI call per meeting.")
                    .font(.caption).foregroundColor(.secondary)
            }

            SettingsGroup("Keyword Radar") {
                KeywordRadarEditor()
            }

            SettingsGroup("Metadata & Notifications") {
                Toggle("Auto-tag topics & entities into front-matter", isOn: $settings.autoTagging)
                Text("After summarizing, extract topic tags plus the people, customer, and project a meeting is about — mirrored into tags and written as structured attendees/customer/project fields (great for Obsidian/Notion graphs and Dataview). Names are skipped when redaction is on. Requires front-matter enabled and network access.")
                    .font(.caption).foregroundColor(.secondary)
                Divider()
                Toggle("Notify when notes are saved", isOn: $settings.notifyOnMeetingEnd)
            }

            SettingsGroup("Ask & Search") {
                Toggle("Agentic Ask across everything", isOn: $settings.agenticAsk)
                Text("When on, Ask plans several searches per question and folds in Catalog facts — accounts, opportunities, POC health, and people — so it can answer structured questions (\u{201C}which POCs are at risk?\u{201D}) as well as \u{201C}what did we decide with Acme?\u{201D}. When off, Ask does a single keyword/meaning search over meeting notes only. Planning uses a cloud call, so it's skipped in Local-only mode.")
                    .font(.caption).foregroundColor(.secondary)
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Search index cache")
                        Text("The on-device semantic search index (Apple NLEmbedding vectors, cached in ~/Library/Caches). Rebuilds automatically as notes change. Private, never uploaded. \(indexedCount) note\(indexedCount == 1 ? "" : "s") indexed.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("Reveal in Finder") {
                        let url = SemanticIndex.cacheFileURL
                        if FileManager.default.fileExists(atPath: url.path) {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        } else {
                            NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()])
                        }
                    }
                    Button("Rebuild Index") {
                        Task {
                            await SemanticIndex.shared.clear()
                            indexedCount = await SemanticIndex.shared.indexedFileCount
                        }
                    }
                    .disabled(indexedCount == 0)
                }
                Divider()
                HStack {
                    Text("Search depth (recent meetings)")
                    Spacer()
                    Picker("", selection: $settings.searchDepth) {
                        ForEach([100, 200, 500, 1000], id: \.self) { Text("\($0)").tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 100)
                    DefaultResetButton(isDefault: settings.searchDepth == AppSettings.Default.searchDepth) {
                        settings.searchDepth = AppSettings.Default.searchDepth
                    }
                }
                Text("How many recent meetings the Catalog's Meaning search and Ask scan. Higher reaches further back but is slower on large archives.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .task { indexedCount = await SemanticIndex.shared.indexedFileCount }
    }

    private func pickNotesFolder() {
        if let url = chooseFolder(startingAt: settings.notesFolder) {
            let oldFolder = settings.notesFolder
            settings.notesFolder = url
            CatalogStore.shared.notesFolderDidChange(from: oldFolder)
        }
    }
}

/// Keyword Radar watchlist editor — a friendly chip UI: type a term and press
/// Return (or Add) to append it, tap a chip's ✕ to remove it, with a bulk
/// paste/edit box tucked into a disclosure for power users. Backed by the same
/// newline-separated `watchlistKeywords` string, so scanning is unaffected.
struct KeywordRadarEditor: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var newTerm = ""
    @State private var showBulk = false
    @FocusState private var addFocused: Bool

    private var terms: [String] { settings.watchlist() }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Flag terms — competitors, product names, risk phrases. Every finished meeting is scanned locally (works offline); matches surface in a Mentions section and, with front-matter on, as filterable tags. See the cross-meeting rollup in Catalog → Tools → Keyword Radar.")
                .font(.caption).foregroundColor(.secondary)

            // Add a term — type and press Return, or hit Add.
            HStack {
                TextField("Add a term…", text: $newTerm)
                    .textFieldStyle(.roundedBorder)
                    .focused($addFocused)
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            // Current terms as removable chips.
            if terms.isEmpty {
                Text("No terms yet — nothing is scanned.")
                    .font(.caption).foregroundColor(.secondary)
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(terms, id: \.self) { term in
                        KeywordChip(term: term) { settings.removeWatchlistTerm(term) }
                    }
                }
                HStack {
                    Text("\(terms.count) term\(terms.count == 1 ? "" : "s") tracked")
                        .font(.caption).foregroundColor(.secondary)
                    Spacer()
                    Button("Clear All", role: .destructive) { settings.watchlistKeywords = "" }
                        .font(.caption)
                }
            }

            // Power-user bulk edit — same underlying list.
            DisclosureGroup(isExpanded: $showBulk) {
                MultilineField(text: $settings.watchlistKeywords,
                               placeholder: "Acme Corp\nlatency\nrenewal",
                               minHeight: 80,
                               font: .system(.caption, design: .monospaced))
                Text("One term per line (commas also work). Edits here stay in sync with the chips above.")
                    .font(.caption).foregroundColor(.secondary)
            } label: {
                Text("Paste or edit as a list").font(.caption)
            }
        }
    }

    private func add() {
        settings.addWatchlistTerms(newTerm)
        newTerm = ""
        addFocused = true
    }
}

/// A single removable watchlist term pill.
struct KeywordChip: View {
    let term: String
    let onRemove: () -> Void
    var body: some View {
        HStack(spacing: 4) {
            Text(term).font(.callout).lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill").font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .help("Remove")
        }
        .pillBackground(.accentColor, opacity: 0.12, hPad: 8, vPad: 3, stroke: 0.25)
    }
}

/// Draft Templates — edit the drafting guidance behind each output document
/// type (the Draft… menu in the note viewer). Each type has an editable
/// instruction with a per-item reset to the built-in default.
/// Meeting templates — split out of Notes & Summaries (which had grown to eight
/// groups). Owns the meeting-type template editor and the shared template
/// import/export, sitting beside Draft Templates under Meetings.
struct MeetingTemplatesPane: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsGroup("Meeting Templates") {
                Text("Each meeting type shapes what the summary extracts and how a follow-up is drafted. Edit the built-ins or add your own.")
                    .font(.caption).foregroundColor(.secondary)
                TemplateManager()
            }
            TemplateTransferSection()
        }
    }
}

/// Pick-and-reorder editor for the Follow-Up Packet's sections. The packet is
/// one composed document, so order is meaningful — sections render top-to-bottom
/// in this list. Any draft-document type can be added; the curated three
/// (email / POC plan / action items) keep their special grounding at generation
/// time regardless of position.
struct PacketSectionsEditor: View {
    @ObservedObject private var settings = AppSettings.shared

    private var ids: [String] { settings.packetSectionIDs }

    /// Draft docs not already in the packet, for the "Add section" menu.
    private var availableGroups: [(title: String, docs: [DraftDoc])] {
        settings.groupedDraftDocs.compactMap { group in
            let docs = group.docs.filter { !ids.contains($0.id) }
            return docs.isEmpty ? nil : (group.title, docs)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("The note viewer's one-click packet assembles these sections, in this order, into a single document grounded in the meeting.")
                .font(.caption).foregroundColor(.secondary)

            if ids.isEmpty {
                Text("No sections — the packet would be empty. Add at least one below.")
                    .font(.caption).foregroundColor(.orange)
            } else {
                ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                    row(index: index, id: id)
                }
            }

            HStack(spacing: 8) {
                Menu {
                    ForEach(availableGroups, id: \.title) { group in
                        Section(group.title) {
                            ForEach(group.docs) { doc in
                                Button(doc.displayName) { settings.packetSectionIDs = ids + [doc.id] }
                            }
                        }
                    }
                } label: {
                    Label("Add section", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(availableGroups.isEmpty)

                Spacer()

                Text("\(ids.count) section\(ids.count == 1 ? "" : "s") · each is a separate AI call")
                    .font(.caption2).foregroundColor(.secondary)

                DefaultResetButton(isDefault: ids == AppSettings.defaultPacketSections) {
                    settings.packetSectionIDs = AppSettings.defaultPacketSections
                }
            }
        }
    }

    @ViewBuilder private func row(index: Int, id: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon(for: id)).foregroundColor(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(label(for: id))
                if let note = groundingNote(for: id) {
                    Text(note).font(.caption2).foregroundColor(.secondary)
                }
            }
            Spacer()
            Button { move(index, by: -1) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.plain).foregroundColor(.secondary)
                .disabled(index == 0)
            Button { move(index, by: 1) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.plain).foregroundColor(.secondary)
                .disabled(index == ids.count - 1)
            Button { settings.packetSectionIDs = ids.filter { $0 != id } } label: {
                Image(systemName: "minus.circle.fill")
            }
            .buttonStyle(.plain).foregroundColor(.secondary).help("Remove")
        }
    }

    private func move(_ index: Int, by offset: Int) {
        var list = ids
        let target = index + offset
        guard list.indices.contains(index), list.indices.contains(target) else { return }
        list.swapAt(index, target)
        settings.packetSectionIDs = list
    }

    private func label(for id: String) -> String {
        settings.allDraftDocs.first { $0.id == id }?.displayName ?? id
    }
    private func icon(for id: String) -> String {
        settings.allDraftDocs.first { $0.id == id }?.icon ?? "doc"
    }
    /// A one-line hint for the sections that get bespoke grounding.
    private func groundingNote(for id: String) -> String? {
        switch id {
        case "pocPlan":        return "Grounded in the linked project's success criteria."
        case "actionItemList": return "Reuses the note's own checklist when it has one."
        case "followUpEmail":  return "Shaped by the meeting type."
        default:               return nil
        }
    }
}

struct DraftTemplatesPane: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var selectedID: String = FollowUpKind.minutes.rawValue
    @State private var text: String = ""
    @State private var name: String = ""

    /// The currently-selected document type, self-healing to the first built-in
    /// if the selected custom template was deleted.
    private var current: DraftDoc {
        settings.allDraftDocs.first { $0.id == selectedID } ?? .builtIn(.minutes)
    }

    private var builtInIsCustomized: Bool {
        if case .builtIn(let k) = current { return settings.hasCustomDraftGuidance(for: k) }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsGroup("Follow-Up Packet") {
                PacketSectionsEditor()
                Divider()
                Toggle("Confirm before generating (uses several cloud-AI calls)", isOn: $settings.packetConfirmBeforeRun)
            }

            SettingsGroup("Document Type") {
                HStack {
                    Picker("Type", selection: $selectedID) {
                        ForEach(settings.groupedDraftDocs, id: \.title) { group in
                            Section(group.title) {
                                ForEach(group.docs) { doc in
                                    Label(doc.displayName, systemImage: doc.icon).tag(doc.id)
                                }
                            }
                        }
                    }
                    .labelsHidden()
                    .onChange(of: selectedID) { _, _ in load() }

                    Button {
                        let id = settings.addUserDraftTemplate(name: "New Document")
                        selectedID = id
                        load()
                    } label: { Image(systemName: "plus") }
                        .help("Add a custom document type")

                    if current.isCustom {
                        Button(role: .destructive) {
                            if case .user(let t) = current {
                                settings.deleteUserDraftTemplate(id: t.id)
                                selectedID = FollowUpKind.minutes.rawValue
                                load()
                            }
                        } label: { Image(systemName: "trash") }
                            .help("Delete this custom document type")
                    }
                }
                if case .builtIn(let k) = current {
                    Text(k.blurb).font(.caption).foregroundColor(.secondary)
                } else {
                    Text("Pick a document type to edit how it's drafted, or add your own. These are the types offered by the note viewer's Draft… menu.")
                        .font(.caption).foregroundColor(.secondary)
                }
            }

            if current.isCustom {
                SettingsGroup("Name") {
                    TextField("Document name", text: $name)
                        .onChange(of: name) { _, newValue in
                            if case .user(let t) = current {
                                settings.updateUserDraftTemplate(id: t.id, name: newValue)
                            }
                        }
                }
            }

            SettingsGroup("\(current.displayName) guidance") {
                MultilineField(text: $text,
                               placeholder: "Describe the recipient, tone, sections, and format the model should use…",
                               minHeight: 200,
                               font: .system(.caption, design: .monospaced))
                    .onChange(of: text) { _, newValue in
                        switch current {
                        case .builtIn(let k): settings.setDraftGuidance(newValue, for: k)
                        case .user(let t):    settings.updateUserDraftTemplate(id: t.id, guidance: newValue)
                        }
                    }
                if !current.isCustom {
                    HStack {
                        Text(builtInIsCustomized ? "Customized" : "Using the built-in default")
                            .font(.caption).foregroundColor(.secondary)
                        Spacer()
                        Button("Reset to Default") {
                            if case .builtIn(let k) = current {
                                settings.setDraftGuidance("", for: k)
                                text = k.guidance
                            }
                        }
                        .disabled(!builtInIsCustomized)
                    }
                }
                Text("The instruction the AI follows for this document — recipient, tone, sections, and format. Draw only from the meeting's notes. Changing it regenerates the document the next time you draft it (each type caches separately).")
                    .font(.caption).foregroundColor(.secondary)
                Divider()
                Text("Looking for a follow-up that adapts to the meeting type (including your custom meeting templates)? That's the note viewer's “Auto — match meeting type” draft, edited under Meeting Templates → follow-up guidance.")
                    .font(.caption).foregroundColor(.secondary)
            }

            // Same shared bundle as Meeting Templates — surfaced here too so
            // email/document templates can be backed up or shared from this pane.
            TemplateTransferSection()
        }
        .onAppear { load() }
    }

    private func load() {
        text = current.guidance
        if case .user(let t) = current { name = t.name }
    }
}

/// Export / import for all custom template data (meeting templates, custom
/// document types, and built-in guidance overrides) as one portable `.json`.
/// Shown in both template panes since one bundle carries everything. Mirrors
/// the Catalog's export/import UX (save/open panel + merge/replace choice).
struct TemplateTransferSection: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var pendingImportData: Data?
    @State private var showImportChoice = false
    @State private var status: String?

    var body: some View {
        SettingsGroup("Backup & Sharing") {
            HStack {
                Button("Export Templates…") { export() }
                    .disabled(!settings.hasExportableTemplates)
                Button("Import Templates…") { beginImport() }
                Spacer()
            }
            if let status {
                Text(status).font(.caption).foregroundColor(.secondary)
            }
            Text("Save your custom meeting templates, custom document types, and any edits to built-in guidance as one .json file — a backup, or a house style to share with teammates. Built-in templates aren't included; only your additions and edits.")
                .font(.caption).foregroundColor(.secondary)
        }
        .confirmationDialog("Import templates", isPresented: $showImportChoice, titleVisibility: .visible) {
            Button("Merge") { runImport(.merge) }
            Button("Replace", role: .destructive) { runImport(.replace) }
            Button("Cancel", role: .cancel) { pendingImportData = nil }
        } message: {
            Text("Merge adds and updates templates from the file, keeping your others. Replace swaps all your custom template data for the file's.")
        }
    }

    private func export() {
        guard let data = try? settings.exportTemplates() else {
            status = "Nothing to export yet."
            return
        }
        if let s = FilePanels.save(defaultName: "GhostWriter-Templates.json", contentTypes: [.json],
                                   successVerb: "Exported to", failVerb: "Export",
                                   write: { try data.write(to: $0, options: .atomic) }) {
            status = s
        }
    }

    private func beginImport() {
        guard let url = FilePanels.openFile(contentTypes: [.json]),
              let data = try? Data(contentsOf: url) else { return }
        guard settings.isValidTemplateBundle(data) else {
            status = "That file isn't a GhostWriter template export."
            return
        }
        pendingImportData = data
        showImportChoice = true
    }

    private func runImport(_ mode: AppSettings.TemplateImportMode) {
        guard let data = pendingImportData else { return }
        pendingImportData = nil
        do {
            let n = try settings.importTemplates(data, mode: mode)
            status = "Imported \(n) template item\(n == 1 ? "" : "s")."
        } catch {
            status = "Import failed: \(error.localizedDescription)"
        }
    }
}

/// Integrations — outbound event hooks fired when a meeting finishes, so users
/// can wire GhostWriter into their own tools. Both destinations are opt-in and
/// suppressed in Local-only mode (a banner explains why they're disabled).
struct IntegrationsPane: View {
    @ObservedObject private var settings = AppSettings.shared

    private var scriptIsValid: Bool {
        let p = settings.scriptHookPath.trimmingCharacters(in: .whitespaces)
        return !p.isEmpty && FileManager.default.isExecutableFile(atPath: p)
    }
    private var webhookIsValid: Bool {
        let u = settings.webhookURL.trimmingCharacters(in: .whitespaces)
        return URL(string: u)?.scheme?.lowercased() == "https"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if settings.localOnlyMode {
                Label("Local-only mode is on, so outbound integrations are disabled — they'd send data off your Mac. Turn off Local-only mode in Privacy to use these.",
                      systemImage: "hand.raised.fill")
                    .font(.caption).foregroundColor(.orange)
            }

            SettingsGroup("When a Meeting Finishes") {
                Text("Fire an event the moment a meeting is saved, carrying the note's metadata (title, date, meeting type, linked org/project, tags) — never the audio. Free-text fields are run through your redaction settings first. Use these to post into Notion, Slack, Zapier, or your own scripts.")
                    .font(.caption).foregroundColor(.secondary)
            }

            SettingsGroup("Local Script Hook") {
                Toggle("Run a script when a meeting finishes", isOn: $settings.scriptHookEnabled)
                    .disabled(settings.localOnlyMode)
                Text("Runs your executable with the event JSON on stdin. No network — the easiest option to trust.")
                    .font(.caption).foregroundColor(.secondary)
                HStack {
                    TextField("/path/to/script.sh", text: $settings.scriptHookPath)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!settings.scriptHookEnabled)
                    Button("Choose…") { chooseScript() }
                        .disabled(!settings.scriptHookEnabled)
                }
                if settings.scriptHookEnabled && !settings.scriptHookPath.isEmpty && !scriptIsValid {
                    Label("Not an executable file — run `chmod +x` on it.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundColor(.orange)
                }
            }

            SettingsGroup("Outgoing Webhook") {
                Toggle("POST to a webhook when a meeting finishes", isOn: $settings.webhookEnabled)
                    .disabled(settings.localOnlyMode)
                Text("Sends the event JSON as an HTTP POST. Must be an https URL.")
                    .font(.caption).foregroundColor(.secondary)
                TextField("https://example.com/hooks/ghostwriter", text: $settings.webhookURL)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!settings.webhookEnabled)
                if settings.webhookEnabled && !settings.webhookURL.isEmpty && !webhookIsValid {
                    Label("Enter a valid https:// URL.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundColor(.orange)
                }
            }

            SettingsGroup("Payload") {
                Text("""
                {
                  "event": "meeting.finished",
                  "title": "Acme SSO Scoping",
                  "file": "…/Meeting_2026-07-13.md",
                  "date": "2026-07-13T10:00:00Z",
                  "durationSeconds": 1830,
                  "meetingType": "Solution Scoping",
                  "organisation": "Acme",
                  "project": "SSO Migration",
                  "project": "Platform",
                  "tags": ["meeting", "sso"]
                }
                """)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .textSelection(.enabled)
            }
        }
    }

    private func chooseScript() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose an executable script to run when a meeting finishes."
        if panel.runModal() == .OK, let url = panel.url {
            settings.scriptHookPath = url.path
        }
    }
}

/// Proactive digest — its own pane (it spans meetings, Catalog relationships,
/// and scheduling, so it doesn't belong under notes formatting). The schedule
/// controls stay visible but disabled until the digest is turned on, so users
/// can see what it does before committing.
struct DigestPane: View {
    @ObservedObject private var settings = AppSettings.shared

    private static let weekdayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    private static func hourLabel(_ h: Int) -> String {
        let period = h < 12 ? "AM" : "PM"
        let hour12 = h % 12 == 0 ? 12 : h % 12
        return "\(hour12) \(period)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsGroup("Proactive Digest") {
                Toggle("Enable digest", isOn: $settings.digestEnabled)
                Text("A scheduled rollup — grouped by relationship — of your recent meetings, open (and overdue) action items, and Catalog relationships that have gone quiet. Opens in an interactive window and is archived as a Digests note. Generated on-device, no API cost. Build one anytime from the menu → Today's Digest.")
                    .font(.caption).foregroundColor(.secondary)
            }

            SettingsGroup("Schedule") {
                HStack {
                    Text("Frequency")
                    Spacer()
                    Picker("", selection: $settings.digestFrequency) {
                        Text("Daily").tag("daily")
                        Text("Weekly").tag("weekly")
                        Text("Monthly").tag("monthly")
                        Text("Yearly").tag("yearly")
                    }
                    .labelsHidden().frame(width: 120)
                }
                if settings.digestFrequency == "weekly" {
                    HStack {
                        Text("Day")
                        Spacer()
                        Picker("", selection: $settings.digestWeekday) {
                            ForEach(Array(Self.weekdayNames.enumerated()), id: \.offset) { i, name in
                                Text(name).tag(i + 1)   // 1 = Sunday
                            }
                        }
                        .labelsHidden().frame(width: 140)
                    }
                }
                HStack {
                    Text("At")
                    Spacer()
                    Picker("", selection: $settings.digestHour) {
                        ForEach(0..<24, id: \.self) { h in Text(Self.hourLabel(h)).tag(h) }
                    }
                    .labelsHidden().frame(width: 100)
                }
                if settings.digestFrequency == "monthly" {
                    Text("Monthly digests run on the 1st.")
                        .font(.caption).foregroundColor(.secondary)
                } else if settings.digestFrequency == "yearly" {
                    Text("Yearly digests run on 1 January.")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            .disabled(!settings.digestEnabled)

            SettingsGroup("Relationships") {
                HStack {
                    Text("Flag relationships quiet after")
                    Spacer()
                    Picker("", selection: $settings.staleRelationshipDays) {
                        ForEach([14, 30, 60, 90], id: \.self) { Text("\($0) days").tag($0) }
                    }
                    .labelsHidden().frame(width: 110)
                }
                Text("An open project with no note in this window is surfaced under \u{201C}Quiet Relationships\u{201D} in the digest.")
                    .font(.caption).foregroundColor(.secondary)
            }
            .disabled(!settings.digestEnabled)
        }
    }
}

/// Manages meeting templates: pick the default, add/rename/delete your own,
/// and edit the section list of whichever is selected. Built-in templates are
/// curated starting points (their sections are editable, resettable); user
/// templates are fully yours (renamable, deletable).
struct TemplateManager: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var confirmingDelete = false

    private var selected: SummaryTemplate { settings.selectedTemplate }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Meeting template")
                Spacer()
                Picker("", selection: $settings.selectedTemplateID) {
                    ForEach(settings.groupedTemplates, id: \.title) { group in
                        Section(group.title) {
                            ForEach(group.templates) { template in
                                Text(template.displayName).tag(template.id)
                            }
                        }
                    }
                }
                .labelsHidden()
                .frame(width: 180)
                Button {
                    settings.selectedTemplateID = settings.addUserTemplate(name: "New Template")
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add a new template")
                if !selected.isBuiltIn {
                    Button(role: .destructive) {
                        confirmingDelete = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .help("Delete this template")
                }
            }
            if case .builtIn(let t) = selected {
                Text(t.blurb).font(.caption).foregroundColor(.secondary)
            } else {
                Text("Shapes what the summary extracts. Also switchable per meeting from the menu bar.")
                    .font(.caption).foregroundColor(.secondary)
            }

            // Name field for user templates (built-in names are fixed).
            if !selected.isBuiltIn {
                TemplateNameField(id: selected.id, name: selected.displayName)
            }

            TemplateSectionsEditor(template: selected)
            TemplateFollowUpEditor(template: selected)
        }
        .alert("Delete “\(selected.displayName)”?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) { settings.deleteUserTemplate(id: selected.id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This template will be removed. Meeting notes already saved are unaffected.")
        }
    }
}

/// Rename field for a user template, committing on change.
struct TemplateNameField: View {
    let id: String
    @ObservedObject private var settings = AppSettings.shared
    @State private var name: String

    init(id: String, name: String) {
        self.id = id
        _name = State(initialValue: name)
    }

    var body: some View {
        HStack {
            Text("Name")
            TextField("Template name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onChange(of: name) { _, newValue in
                    settings.updateUserTemplate(id: id, name: newValue)
                }
        }
        // Re-seed when the picker moves to a different user template.
        .onChange(of: id) { _, _ in name = settings.template(withID: id)?.displayName ?? "" }
    }
}

/// Editor for the summary sections of the selected template. Sections are
/// `Heading: instruction` lines. Built-in overrides can be reset to defaults;
/// user templates just save their text.
struct TemplateSectionsEditor: View {
    let template: SummaryTemplate
    @ObservedObject private var settings = AppSettings.shared
    @State private var text: String = ""

    /// Built-in with no saved override → already at default.
    private var isBuiltInDefault: Bool {
        if case .builtIn(let t) = template {
            return settings.customTemplateSections(for: t) == nil
        }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Sections — one \"Heading: what to extract\" per line.")
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
                if case .builtIn(let t) = template {
                    DefaultResetButton(isDefault: isBuiltInDefault) {
                        settings.setCustomTemplateSections("", for: t)
                        text = t.defaultSectionsText
                    }
                }
            }
            MultilineField(text: $text,
                           placeholder: "## Summary\n## Action Items\n## Decisions",
                           minHeight: 90,
                           font: .system(.caption, design: .monospaced))
                .onChange(of: text) { _, newValue in save(newValue) }
        }
        .onAppear { text = template.sectionsText }
        // Switching the picker re-points this editor at another template.
        .onChange(of: template.id) { _, _ in text = template.sectionsText }
    }

    private func save(_ newValue: String) {
        switch template {
        case .builtIn(let t): settings.setCustomTemplateSections(newValue, for: t)
        case .user(let t):    settings.updateUserTemplate(id: t.id, sections: newValue)
        }
    }
}

/// Editor for the follow-up drafting guidance of the selected template — how
/// the "Draft Follow-up" action shapes its recipient, tone, and content.
/// Built-in overrides can be reset to defaults; user templates just save theirs.
struct TemplateFollowUpEditor: View {
    let template: SummaryTemplate
    @ObservedObject private var settings = AppSettings.shared
    @State private var text: String = ""

    /// Built-in with no saved override → already at default.
    private var isBuiltInDefault: Bool {
        if case .builtIn(let t) = template {
            return settings.customTemplateFollowUp(for: t) == nil
        }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Auto follow-up shape — how the note viewer's “Auto — match meeting type” draft is written for *this* meeting type (recipient, tone, what to include).")
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
                if case .builtIn(let t) = template {
                    DefaultResetButton(isDefault: isBuiltInDefault) {
                        settings.setCustomTemplateFollowUp("", for: t)
                        text = t.followUpGuidance
                    }
                }
            }
            MultilineField(text: $text,
                           placeholder: "Recipient, tone, and what the follow-up should include…",
                           minHeight: 70,
                           font: .system(.caption, design: .monospaced))
                .onChange(of: text) { _, newValue in save(newValue) }
            Text("For explicit document types (Minutes, Follow-up Email, Status Update, …), see Meetings → Draft Templates.")
                .font(.caption).foregroundColor(.secondary)
        }
        .onAppear { text = template.followUpText }
        // Switching the picker re-points this editor at another template.
        .onChange(of: template.id) { _, _ in text = template.followUpText }
    }

    private func save(_ newValue: String) {
        switch template {
        case .builtIn(let t): settings.setCustomTemplateFollowUp(newValue, for: t)
        case .user(let t):    settings.updateUserTemplate(id: t.id, followUp: newValue)
        }
    }
}

