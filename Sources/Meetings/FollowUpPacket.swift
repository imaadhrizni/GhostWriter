import Foundation

/// Assembles a one-click **Follow-Up Packet** from a finished meeting note:
/// a client-ready follow-up email, an updated POC plan (grounded in the linked
/// opportunity's current success criteria), and the meeting's action items —
/// composed into a single Markdown document ready to read, copy, or export as
/// one PDF from the notes viewer.
///
/// Everything is grounded strictly in the note; the sections run concurrently
/// and any one failing degrades to an inline note rather than sinking the whole
/// packet. Which sections are included — and in what order — is user-configurable
/// (Settings → Meetings → Draft Templates → Follow-Up Packet): the three curated
/// sections plus any other draft-document type.
enum FollowUpPacket {

    /// Resolve Catalog context on the main actor, then generate the enabled
    /// sections concurrently. Non-throwing: failures surface as inline text.
    @MainActor
    static func generate(fileURL: URL, forceRefresh: Bool = false) async -> String {
        let settings = AppSettings.shared
        guard let text = fileURL.readText() else {
            return "_Couldn't read the meeting note._"
        }

        // Ground the email on the note's recorded (or inferred) meeting type.
        let template = FrontMatter.field("gw_meeting_type", in: text)
            .flatMap { settings.template(withID: $0) }
            ?? MeetingTemplate.inferred(fromNotes: text).map { SummaryTemplate.builtIn($0) }
            ?? settings.selectedTemplate

        // Catalog context (read on the main actor before any async hops).
        let ctx = catalogContext(for: fileURL)
        // Existing, curated action items straight from the note (deterministic).
        let existingActions = NotesLibrary.actionItems(inFile: fileURL)

        let polisher = TextPolisher()
        let sectionIDs = settings.packetSectionIDs

        let out = header(base: fileURL.deletingPathExtension().lastPathComponent, ctx: ctx, text: text)
        guard !sectionIDs.isEmpty else {
            return out + "\n\n_No packet sections are configured. Add some in Settings → Meetings → Draft Templates._"
        }

        // Kick every section off concurrently, then splice them back together in
        // the user's chosen order (creating all Tasks before the first await lets
        // them overlap, exactly like the old `async let` fan-out).
        let tasks: [Task<String?, Never>] = sectionIDs.map { id in
            Task {
                await produceSection(id: id, text: text, template: template,
                                     criteria: ctx.criteria, existingActions: existingActions,
                                     polisher: polisher, forceRefresh: forceRefresh)
            }
        }

        var result = out
        for task in tasks {
            if let part = await task.value { result += "\n\n" + part }
        }
        return result
    }

    /// Produce one packet section by identifier. The three curated sections get
    /// their bespoke treatment (meeting-type-aware email, criteria-grounded POC
    /// plan, note-sourced action items); any other draft type falls back to a
    /// generic guided draft.
    @MainActor
    private static func produceSection(id: String, text: String, template: SummaryTemplate,
                                       criteria: [(text: String, status: String)],
                                       existingActions: [NotesLibrary.ActionItem],
                                       polisher: TextPolisher, forceRefresh: Bool) async -> String? {
        switch id {
        case "followUpEmail":
            return await section(title: "✉️ Follow-Up Email") {
                try await polisher.draftFollowUp(transcript: text, template: template, forceRefresh: forceRefresh)
            }
        case "pocPlan":
            return await pocPlanSection(text: text, criteria: criteria, polisher: polisher, forceRefresh: forceRefresh)
        case "actionItemList":
            return await actionItemsSection(existing: existingActions, text: text, polisher: polisher, forceRefresh: forceRefresh)
        default:
            guard let doc = AppSettings.shared.allDraftDocs.first(where: { $0.id == id }) else { return nil }
            return await section(title: "📄 \(doc.displayName)") {
                try await polisher.draftDocument(transcript: text, guidance: doc.guidance, forceRefresh: forceRefresh)
            }
        }
    }

    // MARK: - Sections

    /// Wrap an async producer in a "## title" section, degrading to an inline
    /// note if it throws so one failure doesn't sink the packet.
    private static func section(title: String,
                                _ produce: () async throws -> String) async -> String {
        do {
            let body = try await produce().trimmingCharacters(in: .whitespacesAndNewlines)
            return "## \(title)\n\n" + (body.isEmpty ? "_Nothing to include._" : body)
        } catch {
            return "## \(title)\n\n_Couldn't generate this section: \(error.localizedDescription)_"
        }
    }

    /// POC plan grounded in the opportunity's current criteria when present:
    /// a deterministic status snapshot from the Catalog + an AI plan that
    /// focuses next steps on the unmet criteria. Falls back to a fresh plan
    /// when the note isn't linked to an opportunity with criteria.
    private static func pocPlanSection(text: String, criteria: [(text: String, status: String)],
                                       polisher: TextPolisher, forceRefresh: Bool) async -> String {
        let (guidance, snapshot) = PocPlanGrounding.apply(
            baseGuidance: AppSettings.shared.draftGuidance(for: .pocPlan), criteria: criteria)
        return await section(title: "🧪 POC Plan") {
            let plan = try await polisher.draftDocument(transcript: text, guidance: guidance, forceRefresh: forceRefresh)
            return snapshot + plan
        }
    }

    /// Action items: reuse the note's curated `## Action Items` when it has any
    /// (deterministic, no token spend); otherwise draft them from the transcript.
    private static func actionItemsSection(existing: [NotesLibrary.ActionItem], text: String,
                                           polisher: TextPolisher, forceRefresh: Bool) async -> String {
        if !existing.isEmpty {
            let list = existing.map { "- [\($0.done ? "x" : " ")] \($0.text)" }.joined(separator: "\n")
            return "## ✅ Action Items\n\n" + list
        }
        return await section(title: "✅ Action Items") {
            try await polisher.draftDocument(
                transcript: text,
                guidance: AppSettings.shared.draftGuidance(for: .actionItemList),
                forceRefresh: forceRefresh)
        }
    }

    // MARK: - Header & Catalog

    private static func header(base: String,
                               ctx: (org: String?, project: String?, criteria: [(text: String, status: String)]),
                               text: String) -> String {
        var meta: [String] = []
        if let proj = ctx.project { meta.append("**Project:** \(proj)") }
        if let org = ctx.org { meta.append("**Account:** \(org)") }
        if let title = FrontMatter.title(in: text) { meta.append("**Meeting:** \(title)") }
        let sub = meta.isEmpty ? "" : "\n\n" + meta.joined(separator: " · ")
        return "# Follow-Up Packet\n\n_Generated from \(base)._" + sub
    }

    /// Resolve the note's linked project + account and its POC criteria,
    /// via the shared `CatalogStore.linkChain` resolver.
    @MainActor
    private static func catalogContext(for fileURL: URL)
        -> (org: String?, project: String?, criteria: [(text: String, status: String)]) {
        let c = CatalogStore.shared.linkChain(forFileURL: fileURL)
        return (c.org, c.project, c.criteria.map { ($0.text, $0.status.label) })
    }
}
