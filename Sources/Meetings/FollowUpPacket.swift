import Foundation

/// Assembles a one-click **Follow-Up Packet** from a finished meeting note:
/// a client-ready follow-up email, an updated POC plan (grounded in the linked
/// opportunity's current success criteria), and the meeting's action items —
/// composed into a single Markdown document ready to read, copy, or export as
/// one PDF from the notes viewer.
///
/// Everything is grounded strictly in the note; the three AI sections run
/// concurrently, and any one failing degrades to an inline note rather than
/// sinking the whole packet. Which sections are included is user-configurable
/// (Settings → Meetings → Draft Templates → Follow-Up Packet).
enum FollowUpPacket {

    /// Resolve Catalog context on the main actor, then generate the enabled
    /// sections concurrently. Non-throwing: failures surface as inline text.
    @MainActor
    static func generate(fileURL: URL, forceRefresh: Bool = false) async -> String {
        let settings = AppSettings.shared
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
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
        let wantEmail = settings.packetIncludeEmail
        let wantPOC = settings.packetIncludePOC
        let wantActions = settings.packetIncludeActions

        // Fire the AI sections concurrently.
        async let emailSection: String? = wantEmail
            ? section(title: "✉️ Follow-Up Email") {
                try await polisher.draftFollowUp(transcript: text, template: template, forceRefresh: forceRefresh)
            } : nil

        async let pocSection: String? = wantPOC
            ? pocPlanSection(text: text, criteria: ctx.criteria, polisher: polisher, forceRefresh: forceRefresh)
            : nil

        // Action items: prefer the note's curated list; only ask the model when
        // the note has none recorded yet.
        async let actionsSection: String? = wantActions
            ? actionItemsSection(existing: existingActions, text: text, polisher: polisher, forceRefresh: forceRefresh)
            : nil

        var out = header(base: fileURL.deletingPathExtension().lastPathComponent, ctx: ctx, text: text)
        for part in await [emailSection, pocSection, actionsSection].compactMap({ $0 }) {
            out += "\n\n" + part
        }
        if !wantEmail && !wantPOC && !wantActions {
            out += "\n\n_No packet sections are enabled. Turn some on in Settings → Meetings → Draft Templates._"
        }
        return out
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
        var guidance = AppSettings.shared.draftGuidance(for: .pocPlan)
        var snapshot = ""
        if !criteria.isEmpty {
            snapshot = "**Current success criteria**\n\n"
                + criteria.map { "- \(glyph($0.status)) \($0.text) — _\($0.status)_" }.joined(separator: "\n")
                + "\n\n"
            let list = criteria.map { "- [\($0.status)] \($0.text)" }.joined(separator: "\n")
            guidance += "\n\nThe opportunity already has these POC success criteria and statuses:\n\(list)\n"
                + "Reflect them in the plan: keep the passed ones, and focus Timeline & Next Steps on advancing the pending or failed ones."
        }
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
                               ctx: (org: String?, opportunity: String?, criteria: [(text: String, status: String)]),
                               text: String) -> String {
        var meta: [String] = []
        if let opp = ctx.opportunity { meta.append("**Opportunity:** \(opp)") }
        if let org = ctx.org { meta.append("**Account:** \(org)") }
        if let title = FrontMatter.title(in: text) { meta.append("**Meeting:** \(title)") }
        let sub = meta.isEmpty ? "" : "\n\n" + meta.joined(separator: " · ")
        return "# Follow-Up Packet\n\n_Generated from \(base)._" + sub
    }

    /// Resolve the note's linked opportunity + account and its POC criteria,
    /// via the shared `CatalogStore.linkChain` resolver.
    @MainActor
    private static func catalogContext(for fileURL: URL)
        -> (org: String?, opportunity: String?, criteria: [(text: String, status: String)]) {
        let c = CatalogStore.shared.linkChain(forFileURL: fileURL)
        return (c.org, c.opportunity, c.criteria.map { ($0.text, $0.status.label) })
    }

    /// A checklist glyph for a POC status label.
    private static func glyph(_ status: String) -> String {
        switch status.lowercased() {
        case "passed": return "✅"
        case "failed": return "❌"
        default:       return "⬜️"
        }
    }
}
