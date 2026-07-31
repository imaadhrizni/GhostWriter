import Foundation

// MARK: - Output document types
//
// The KIND of document you draft from a meeting is a separate axis from the
// meeting's template: one meeting can yield minutes, a follow-up email, a
// status update, and more. Each kind carries its own drafting guidance and
// caches independently.

enum FollowUpKind: String, CaseIterable, Identifiable {
    case minutes, followUpEmail, statusUpdate, executiveSummary, actionItemList, thankYou
    case recap, decisionLog, talkingPoints, retrospective, faq, proposal, pocPlan
    case solutionSummary, requirementsChecklist, mutualActionPlan

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .minutes:          return "Minutes of Meeting"
        case .followUpEmail:    return "Follow-up Email"
        case .statusUpdate:     return "Status Update"
        case .executiveSummary: return "Executive Summary"
        case .actionItemList:   return "Action-Item List"
        case .thankYou:         return "Thank-You Note"
        case .recap:            return "Quick Recap"
        case .decisionLog:      return "Decision Log"
        case .talkingPoints:    return "Talking Points"
        case .retrospective:    return "Retrospective"
        case .faq:              return "FAQ"
        case .proposal:         return "Proposal / Next Steps"
        case .pocPlan:          return "POC Plan"
        case .solutionSummary:      return "Solution Architecture Summary"
        case .requirementsChecklist: return "Requirements & Config Checklist"
        case .mutualActionPlan:     return "Mutual Action Plan"
        }
    }

    /// Short menu icon.
    var icon: String {
        switch self {
        case .minutes:          return "list.bullet.rectangle"
        case .followUpEmail:    return "envelope"
        case .statusUpdate:     return "chart.bar.doc.horizontal"
        case .executiveSummary: return "text.alignleft"
        case .actionItemList:   return "checklist"
        case .thankYou:         return "hand.thumbsup"
        case .recap:            return "text.bubble"
        case .decisionLog:      return "checkmark.seal"
        case .talkingPoints:    return "bubble.left.and.bubble.right"
        case .retrospective:    return "arrow.triangle.2.circlepath"
        case .faq:              return "questionmark.circle"
        case .proposal:         return "doc.badge.gearshape"
        case .pocPlan:          return "flask"
        case .solutionSummary:      return "square.stack.3d.up"
        case .requirementsChecklist: return "list.bullet.clipboard"
        case .mutualActionPlan:     return "person.2.badge.gearshape"
        }
    }

    /// Category used to group the draft-document pickers and menus.
    enum Category: String, CaseIterable {
        case emailRecap, records, sales, technical, reports, retro
        var title: String {
            switch self {
            case .emailRecap:  return "Email & Recap"
            case .records:     return "Records"
            case .sales:       return "Sales"
            case .technical:   return "Technical"
            case .reports:     return "Reports"
            case .retro:       return "Retro"
            }
        }
    }

    var category: Category {
        switch self {
        case .followUpEmail, .recap, .thankYou:        return .emailRecap
        case .minutes, .decisionLog, .actionItemList:  return .records
        case .proposal, .pocPlan, .talkingPoints:      return .sales
        case .solutionSummary, .requirementsChecklist, .mutualActionPlan: return .technical
        case .statusUpdate, .executiveSummary, .faq:   return .reports
        case .retrospective:                           return .retro
        }
    }

    /// One-line description of what this document is, shown under the picker.
    var blurb: String {
        switch self {
        case .minutes:          return "Formal minutes — attendees, agenda, decisions, and action items."
        case .followUpEmail:    return "A ready-to-send recap email to the participants."
        case .statusUpdate:     return "A skimmable Done / In progress / Blocked / Next update."
        case .executiveSummary: return "A 3–5 sentence brief for a leader who wasn't there."
        case .actionItemList:   return "Just the action items, as an owner-tagged checklist."
        case .thankYou:         return "A short, warm thank-you note to the participants."
        case .recap:            return "A ten-second bullet recap for people who missed it."
        case .decisionLog:      return "A table of decisions with rationale, owner, and date."
        case .talkingPoints:    return "Key messages to say when briefing someone on the meeting."
        case .retrospective:    return "What went well / didn't, plus improvement action items."
        case .faq:              return "The meeting's questions and answers as Q&A pairs."
        case .proposal:         return "A short proposal memo — context, recommendation, next steps."
        case .pocPlan:          return "A proof-of-concept plan — objective, success criteria, scope, timeline."
        case .solutionSummary:      return "A technical solution-architecture recap — requirements, proposed design, and integration points."
        case .requirementsChecklist: return "The customer's technical requirements & environment as an owner-tagged checklist."
        case .mutualActionPlan:     return "A shared vendor↔customer plan of dated milestones toward a decision."
        }
    }

    /// The drafting instruction fed to the model for this document type.
    var guidance: String {
        switch self {
        case .minutes:
            return """
            Write formal MINUTES OF MEETING in Markdown. Include, as sections with "## " headings: Attendees (if identifiable), Agenda / Topics Discussed, Decisions, and Action Items (a "- [ ] <action> — @<owner> (due: <date>)" checklist). Neutral, factual, third-person. Omit a section only if there is genuinely nothing for it.
            """
        case .followUpEmail:
            return """
            Write a follow-up EMAIL to the participants. Format exactly as:
            **Subject:** <a concise, specific subject line>

            Hi <name>,

            <1–2 short paragraphs recapping key outcomes and confirming commitments, then next steps with owners and timing>

            Best regards,
            <signature>
            Leave "<name>" / "<signature>" as placeholders if unclear. Professional and warm.
            """
        case .statusUpdate:
            return """
            Write a short STATUS UPDATE for a manager or team channel, bullet-led under bold labels: **Done**, **In progress**, **Blocked**, **Next**. Terse and skimmable. Omit a label with nothing under it.
            """
        case .executiveSummary:
            return """
            Write a 3–5 sentence EXECUTIVE SUMMARY for a leader who wasn't present: the purpose, the key outcome or decision, and the single most important next step. Prose, no bullets, no heading.
            """
        case .actionItemList:
            return """
            Output ONLY the action items as a Markdown checklist, one per line: "- [ ] <action> — @<owner> (due: <date>)". Append "@<owner>" and "(due: <date>)" only when the notes make them clear. No other sections, headings, or prose. If there are none, output "_No action items._".
            """
        case .thankYou:
            return """
            Write a brief, warm THANK-YOU NOTE to the participants for their time, referencing one or two specifics from the discussion. A short paragraph; no action items unless essential.
            """
        case .recap:
            return """
            Write a QUICK RECAP for people who missed the meeting — 3–6 tight bullets covering what was discussed, what was decided, and what happens next. No headings, no preamble. Skimmable in ten seconds.
            """
        case .decisionLog:
            return """
            Output a DECISION LOG — only the decisions made, as a Markdown table with columns: Decision | Rationale | Owner | Date. One row per decision; leave a cell blank if the notes don't say. If no decisions were made, output "_No decisions recorded._". No other prose.
            """
        case .talkingPoints:
            return """
            Write TALKING POINTS for someone briefing another person or group on this meeting — a bullet list of the key messages, framed as things to say, each one sentence. Group under bold labels if there are natural themes. Confident and concise; no filler.
            """
        case .retrospective:
            return """
            Write a RETROSPECTIVE in Markdown with three "## " sections: What Went Well, What Didn't, and Action Items (a "- [ ] <action> — @<owner>" checklist). Draw only on the discussion; keep each bullet specific and blameless.
            """
        case .faq:
            return """
            Turn the discussion into an FAQ — the questions raised and the answers given, as "**Q:** …" / "**A:** …" pairs, one blank line between pairs. Only include questions actually answered in the notes. No intro or outro. If the notes contain no clear questions and answers, output only "_No Q&A captured._".
            """
        case .proposal:
            return """
            Write a short PROPOSAL / NEXT-STEPS memo in Markdown: "## Context" (1–2 sentences on the situation), "## Proposal" (what's being recommended), and "## Next Steps" (a "- [ ] <step> — @<owner> (due: <date>)" checklist). Persuasive but grounded strictly in the notes.
            """
        case .pocPlan:
            return """
            Write a PROOF-OF-CONCEPT (POC) PLAN in Markdown for a technical evaluation, with "## " sections: Objective (what the POC must prove), Success Criteria (specific, measurable pass/fail items as a bullet list), Scope & Use Cases (what will and won't be tested), Environment & Prerequisites (access, data, accounts needed — from either side), Timeline & Milestones (phases with target dates), Roles (who owns what, on the vendor and customer side), and Risks / Open Questions. Draw strictly on the notes; where a detail wasn't discussed, add it as a bracketed placeholder like "[TBD: …]" rather than inventing it.
            """
        case .solutionSummary:
            return """
            Write a SOLUTION ARCHITECTURE SUMMARY for a technical evaluation, in Markdown with "## " sections: Requirements (the customer's stated technical needs and constraints), Proposed Solution (the architecture/approach discussed, component by component), Integration Points (systems, APIs, data flows, auth it must connect to), Assumptions & Dependencies, and Open Technical Questions. Precise and vendor-neutral in tone. Draw strictly on the notes; mark anything not discussed as "[TBD: …]".
            """
        case .requirementsChecklist:
            return """
            Output the customer's TECHNICAL REQUIREMENTS & ENVIRONMENT as a Markdown checklist, grouped under "## " headings where natural (e.g. Functional, Security & Compliance, Environment & Access, Integrations, Performance/Scale). Each item: "- [ ] <requirement> — @<owner> (due: <date>)", appending owner/date only when the notes make them clear. Capture must-haves and stated constraints; don't invent requirements. If none are captured, output "_No requirements captured._".
            """
        case .mutualActionPlan:
            return """
            Write a MUTUAL ACTION PLAN (MAP) — a shared vendor↔customer plan toward a decision — as a Markdown table with columns: Milestone | Owner (Vendor/Customer) | Target Date | Status. Order rows chronologically toward the goal (e.g. POC start → success-criteria sign-off → business case → decision). Use "[TBD]" for dates not yet agreed and default Status to "Not started". Below the table add a one-line "**Decision target:** <date or [TBD]>". Draw strictly on the notes.
            """
        }
    }
}

/// A user-defined output document type — a name plus free-form drafting
/// guidance. Sits alongside the built-in `FollowUpKind` set.
struct UserDraftTemplate: Codable, Identifiable, Equatable {
    var id: String          // "draft:UUID"
    var name: String
    var guidance: String
}

/// A draft document type offered by the Draft… menu and Draft Templates pane —
/// either a built-in `FollowUpKind` (whose guidance may be overridden in
/// Settings) or a user-defined template.
enum DraftDoc: Identifiable, Equatable {
    case builtIn(FollowUpKind)
    case user(UserDraftTemplate)

    var id: String {
        switch self {
        case .builtIn(let k): return k.rawValue
        case .user(let t):    return t.id
        }
    }

    var displayName: String {
        switch self {
        case .builtIn(let k): return k.displayName
        case .user(let t):    return t.name
        }
    }

    var icon: String {
        switch self {
        case .builtIn(let k): return k.icon
        case .user:           return "doc.text"
        }
    }

    var isCustom: Bool { if case .user = self { return true }; return false }

    /// The resolved drafting guidance — the built-in's (possibly overridden)
    /// guidance, or the user template's own.
    var guidance: String {
        switch self {
        case .builtIn(let k): return AppSettings.shared.draftGuidance(for: k)
        case .user(let t):    return t.guidance
        }
    }

    /// True for the built-in POC-plan draft — the one type grounded in the
    /// project's tracked success criteria rather than re-inventing them.
    var isPocPlan: Bool { self == .builtIn(.pocPlan) }
}

// MARK: - POC-plan criteria grounding

/// Shared grounding for the POC-plan draft: when the note's linked project
/// already tracks success criteria, feed those (with their pass/pending/fail
/// status) into the draft so the plan builds on them instead of generating a
/// fresh, disconnected set. Used by BOTH the standalone Draft… menu and the
/// Follow-Up Packet, so criteria are authored once (in the tracker) and only
/// referenced here. Returns the guidance to send plus a snapshot to prepend to
/// the result ("" when the project has no criteria).
enum PocPlanGrounding {
    static func apply(baseGuidance: String,
                      criteria: [(text: String, status: String)]) -> (guidance: String, snapshot: String) {
        guard !criteria.isEmpty else { return (baseGuidance, "") }
        let snapshot = "**Current success criteria**\n\n"
            + criteria.map { "- \(glyph($0.status)) \($0.text) — _\($0.status)_" }.joined(separator: "\n")
            + "\n\n"
        let list = criteria.map { "- [\($0.status)] \($0.text)" }.joined(separator: "\n")
        let guidance = baseGuidance
            + "\n\nThe project already has these POC success criteria and statuses:\n\(list)\n"
            + "Reflect them in the plan: keep the passed ones, and focus Timeline & Next Steps on advancing the pending or failed ones."
        return (guidance, snapshot)
    }

    /// A checklist glyph for a POC status label.
    static func glyph(_ status: String) -> String {
        switch status.lowercased() {
        case "passed": return "✅"
        case "failed": return "❌"
        default:       return "⬜️"
        }
    }
}

// MARK: - Text Polisher

/// Stage 2 of the Brain pipeline.
/// Takes raw transcribed text + active app context and polishes it
/// using Groq's Llama-3.3-70b model.
///
/// The polishing is context-aware: different apps get different writing styles.
final class TextPolisher {

    // MARK: - Configuration

    /// Groq API key — read from Keychain (never stored in source).
    private var apiKey: String { KeychainService.groqAPIKey() ?? "" }

    /// OpenAI-compatible API base URL (Groq by default; user-configurable).
    private var baseURL: String { AppSettings.shared.apiBaseURL }
    private let session = URLSession.shared
    // Model ids resolve the user's choice against Groq's live catalog (see
    // ModelResolver): an unavailable pick routes to the best available fallback
    // for the role, so a Groq deprecation degrades gracefully instead of failing.
    private var model: String { ModelResolver.shared.resolve(.summary, configured: AppSettings.shared.polishingModel) }
    /// Cheap/fast model for lightweight, high-frequency work (live brief,
    /// tagging, query expansion, agenda coverage) — keeps latency and cost low.
    private var fastModel: String { ModelResolver.shared.resolve(.lightweight, configured: AppSettings.shared.fastModel) }

    // Prompt versions for the AICache. Bump the matching one whenever a cached
    // method's system prompt changes, so stale cached outputs miss and refresh.
    private static let briefPromptVersion = 1
    private static let followUpPromptVersion = 3   // structured Subject/body email format

    /// How a follow-up should be laid out, appended to every template's
    /// guidance. Emails get an explicit Subject line + greeting/body/sign-off;
    /// internal recaps get a titled, skimmable structure.
    private static let followUpFormat = """
    FORMAT — use Markdown:
    - If this is an EMAIL to someone, format it exactly as:
      **Subject:** <a concise, specific subject line>

      <greeting, e.g. "Hi <name>,">

      <the body: 1–2 short paragraphs and/or bullets covering the key points, \
      commitments, and next steps with owners and dates>

      <a brief sign-off>
      Leave "<name>" as a placeholder if the recipient isn't clear.
    - If this is an INTERNAL recap/debrief (not addressed to someone), start with a \
      short "## <Title>" heading, then skimmable bullets grouped under bold labels.
    """

    /// Strip the leading YAML front-matter block and trailing whitespace from a
    /// note before summarizing. The front-matter (tags, attendees) is derived
    /// metadata that auto-tagging and speaker-renaming rewrite without changing
    /// the meeting's substance — leaving it in churns the AI cache (a cosmetic
    /// tag edit would force a re-summary) and wastes input tokens. The body is
    /// what we actually summarize.
    private static func summarizableBody(_ text: String) -> String {
        FrontMatter.body(text).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Model id under which on-device (Apple Intelligence) results are cached,
    /// kept distinct from the Groq model so cloud and local results never shadow
    /// each other but both can be reused.
    static let appleModelID = "apple-on-device"
    private static let appleFooter = "\n\n_— generated on-device with Apple Intelligence_"

    /// Run a cached generation with graceful degradation:
    ///  • Local-only mode → straight to the on-device model (never touches the network).
    ///  • Otherwise → Groq first; on failure, fall back to the on-device model.
    /// Cloud results cache under the Groq model id, on-device under `appleModelID`;
    /// both are consulted on lookup so an offline result is reused next time too.
    private func generateCached(kind: AICache.Kind, source: String, version: Int,
                                forceRefresh: Bool, footer: Bool,
                                groq: () async throws -> String,
                                apple: () async -> String?) async throws -> String {
        if !forceRefresh {
            if let c = AICache.shared.value(kind, source: source, model: model, version: version) { return c }
            if let c = AICache.shared.value(kind, source: source, model: Self.appleModelID, version: version) { return c }
        }
        func storeApple(_ text: String) -> String {
            let out = footer ? text + Self.appleFooter : text
            AICache.shared.store(out, kind: kind, source: source, model: Self.appleModelID, version: version)
            return out
        }
        // Local-only mode: on-device only, never touches the network.
        if AppSettings.shared.localOnlyMode {
            if let a = await apple() { return storeApple(a) }
            throw GroqError.apiError(statusCode: 0,
                message: "On-device AI unavailable. \(AppleIntelligence.unavailableReason ?? "")")
        }
        // User preference: prefer the on-device model when it's available, and
        // only fall back to Groq if it isn't (or produced nothing).
        if AppSettings.shared.preferOnDeviceAI, AppleIntelligence.isAvailable {
            if let a = await apple() { return storeApple(a) }
        }
        guard !apiKey.isEmpty else {
            if let a = await apple() { return storeApple(a) }
            throw GroqError.missingAPIKey
        }
        do {
            let r = try await groq()
            AICache.shared.store(r, kind: kind, source: source, model: model, version: version)
            return r
        } catch {
            // Groq failed (rate limit, offline, …) — try the on-device model.
            if let a = await apple() { return storeApple(a) }
            throw error
        }
    }

    // MARK: - Polishing

    /// Polish the raw transcription text based on the active app context.
    /// - Parameters:
    ///   - rawText: The raw transcription from Whisper
    ///   - appContext: The currently active application info
    /// - Returns: Polished, context-appropriate text
    func polish(rawText: String, appContext: AppContext) async throws -> String {
        guard !apiKey.isEmpty else {
            // If no API key, return raw text (graceful degradation)
            return rawText
        }
        // Local-only mode never contacts the network — skip polishing.
        guard !AppSettings.shared.localOnlyMode else { return rawText }

        let systemPrompt = buildSystemPrompt(for: appContext)
        let userPrompt = """
        Polish the following dictated text. Return ONLY the polished text, nothing else.
        Do not add quotes, explanations, or meta-commentary.

        Dictated text: \(rawText)
        """

        let requestBody = ChatRequest(
            model: model,
            messages: [
                .init(role: "system", content: systemPrompt),
                .init(role: "user", content: userPrompt)
            ],
            temperature: 0.3,
            max_tokens: 2048
        )

        // Graceful degradation: on any failure, return the raw text unchanged.
        do {
            return try await send(requestBody, timeout: 15, source: "Dictation polish")
        } catch {
            Log.api.warning("⚠️ Polishing failed — returning raw text")
            return rawText
        }
    }

    // MARK: - Meeting Summaries

    /// Summarize a meeting transcript. Sections come from the meeting
    /// template; Action Items is appended when enabled.
    func summarize(transcript: String,
                   template: SummaryTemplate = .builtIn(.general),
                   includeSummary: Bool = true,
                   includeActionItems: Bool = true,
                   includeStructured: Bool = false,
                   includeOpenQuestions: Bool = false) async throws -> String {
        guard !apiKey.isEmpty else { throw GroqError.missingAPIKey }
        guard includeSummary || includeActionItems || includeStructured || includeOpenQuestions else {
            throw GroqError.invalidResponse
        }

        // Long meetings exceed the context window. Rather than dropping the
        // opening (a tail-only clip), map-reduce: condense the whole meeting in
        // chunks first, so early decisions survive into the summary.
        let clipped = await condenseIfNeeded(transcript, cap: AppSettings.shared.summaryContextChars)

        var sections: [String] = []
        if includeSummary {
            sections.append(contentsOf: template.summarySections)
        }
        if includeStructured {
            sections.append("""
            A section with the exact heading "## Decisions" listing, as Markdown bullets, the concrete decisions the meeting reached. Body "_None_" if none.
            """)
            sections.append("""
            A section with the exact heading "## Risks & Blockers" listing, as Markdown bullets, risks, blockers, or concerns raised. Body "_None_" if none.
            """)
        }
        if includeOpenQuestions {
            // The single source of "open questions" — folded into the summary
            // pass (no separate round-trip). Strict answered-vs-open judgment,
            // written as a checkbox task list so each is trackable / tickable
            // in the Catalog.
            sections.append("""
            A section with the exact heading "## Open Questions" listing, as a Markdown checkbox task list ("- [ ] <question>"), ONLY genuinely open questions to follow up on: a question was explicitly asked AND no answer or resolution appears anywhere later in the transcript. Before listing one, confirm no later line answers it and drop it if any does. Exclude rhetorical questions, small talk, and anything addressed even partially or informally. Bias strongly toward leaving a question OUT when unsure. Body "_None_" if there are none.
            """)
        }
        if includeActionItems {
            sections.append("""
            A section with the exact heading "## Action Items" containing a Markdown task list. Format each item as "- [ ] <action> — @<owner> (due: <date>)". Append "@<owner>" (one word, no spaces) only when the transcript makes the responsible person clear, and "(due: <date>)" only when a deadline is stated; otherwise leave that part off. If there are no action items, still include the heading with "_None_" as its body.
            """)
        }

        let requestBody = ChatRequest(
            model: model,
            messages: [
                .init(role: "system", content: """
                You summarize meeting transcripts. Produce concise Markdown with exactly these sections:
                \(sections.joined(separator: "\n"))
                Rules:
                - Do not invent content that is not in the transcript.
                - Always include EVERY section heading listed above, in that order — even when a section is empty. When a section has nothing, write exactly "_None_" as its body. Ignore any "(omit if none)" note in a section's description; never drop a heading.
                - Never repeat a heading.
                - Cite sources: transcript lines begin with a timestamp like **[HH:MM:SS]** (a pre-condensed input keeps them as "[HH:MM:SS]" at the start of a bullet). When a point comes from a specific moment, append that source timestamp in brackets at the END of the point, e.g. "- Agreed to ship Friday [00:14:02]". Use only a timestamp that actually appears in the input; omit it when unsure. Never put a timestamp on the TL;DR.
                - If the ENTIRE meeting has too little substantive discussion to summarize at all, output exactly NOT_ENOUGH_CONTENT and nothing else.
                """),
                .init(role: "user", content: "Summarize this meeting transcript:\n\n\(clipped)")
            ],
            temperature: 0.2,
            max_tokens: 1024
        )
        return try await send(requestBody, timeout: 30, source: "Meeting summary")
    }

    /// Map step of map-reduce summarization: when a transcript is longer than
    /// `cap`, condense it chunk-by-chunk into timestamped bullets that preserve
    /// every decision / action / owner / date / number, so the whole meeting —
    /// not just its tail — reaches the final summary. Returns the transcript
    /// unchanged when it already fits, and degrades to a tail-clip on failure.
    private func condenseIfNeeded(_ transcript: String, cap: Int) async -> String {
        guard transcript.count > cap else { return transcript }
        // Bound the number of chunks so a marathon meeting can't fan out into
        // dozens of calls; oversized inputs just use larger chunks.
        let maxChunks = 12
        let chunkSize = max(12_000, Int((Double(transcript.count) / Double(maxChunks)).rounded(.up)))
        let chunks = Self.splitOnLines(transcript, maxChars: chunkSize)

        var condensed: [String] = []
        for chunk in chunks {
            let body = ChatRequest(
                model: fastModel,   // cheap: this is compression, not the final prose
                messages: [
                    .init(role: "system", content: """
                    Condense this meeting-transcript segment into terse Markdown bullets, preserving EVERY decision, action item, owner, date, number, and key point. Start each bullet with the source timestamp in brackets, taken from the line the point came from, like "- [00:12:33] …". Drop small talk. No preamble, no headings — bullets only.
                    """),
                    .init(role: "user", content: chunk)
                ],
                temperature: 0.1,
                max_tokens: 700
            )
            if let text = try? await send(body, timeout: 30, role: .lightweight, source: "Summary condense") {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { condensed.append(trimmed) }
            } else {
                // Keep the chunk's head so its content isn't lost entirely.
                condensed.append(String(chunk.prefix(1_500)))
            }
        }
        let joined = condensed.joined(separator: "\n")
        return joined.isEmpty ? String(transcript.suffix(cap))
             : (joined.count > cap ? String(joined.suffix(cap)) : joined)
    }

    /// Split text into pieces of at most `maxChars`, breaking only at line
    /// boundaries so a transcript line (and its timestamp) is never cut in two.
    static func splitOnLines(_ text: String, maxChars: Int) -> [String] {
        var chunks: [String] = []
        var current = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if current.count + line.count + 1 > maxChars, !current.isEmpty {
                chunks.append(current)
                current = ""
            }
            current += line + "\n"
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { chunks.append(current) }
        return chunks
    }

    /// Segment a transcript into a handful of topical chapters, each anchored to
    /// a timestamp that appears in the transcript (lines start with `**[HH:MM:SS]**`).
    /// Returns Markdown bullet lines, or "" when there's too little to segment.
    func chapters(transcript: String) async throws -> String {
        guard !apiKey.isEmpty else { throw GroqError.missingAPIKey }
        let clipped = String(transcript.suffix(AppSettings.shared.summaryContextChars))

        let requestBody = ChatRequest(
            model: model,
            messages: [
                .init(role: "system", content: """
                You split a meeting transcript into 3–8 topical chapters. Every transcript line begins with a wall-clock timestamp like **[14:03:12]**. Output ONLY a Markdown bullet list, one chapter per line, formatted exactly:
                - [HH:MM:SS] Chapter title
                Use a timestamp that actually appears in the transcript, at the point each topic begins; the first chapter should use the earliest timestamp. Titles are 2–6 words, no trailing punctuation. Do not invent content. If the meeting is too short or covers a single topic, output exactly NONE and nothing else.
                """),
                .init(role: "user", content: clipped)
            ],
            temperature: 0.2,
            max_tokens: 400
        )

        let content = try await send(requestBody, timeout: 30, source: "Chapters")
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == "NONE" ? "" : trimmed
    }

    /// Extract POC success criteria from one or more meeting transcripts — the
    /// measurable outcomes the proof-of-concept must prove (acceptance criteria,
    /// "success looks like…", must-work requirements). Returns one criterion per
    /// line, no bullets/numbering, or "" when none are stated. Used by the
    /// Catalog's POC tracker to seed criteria from an opportunity's meetings.
    func extractPocCriteria(transcript: String) async throws -> [String] {
        guard !apiKey.isEmpty else { throw GroqError.missingAPIKey }
        let clipped = String(Self.summarizableBody(transcript).prefix(20_000))
        let requestBody = ChatRequest(
            model: model,   // measurable-criterion extraction is judgment-heavy — use the polishing model
            messages: [
                .init(role: "system", content: """
                From this meeting transcript, extract the proof-of-concept SUCCESS CRITERIA — the \
                specific, measurable outcomes the POC must demonstrate to be accepted (acceptance \
                criteria, "success looks like…", must-work requirements, agreed evaluation points). \
                Phrase each as a concise, testable statement (e.g. "SSO login works with Azure AD", \
                "Handles 10k concurrent users"). One criterion per line, no bullets, no numbering, \
                no preamble. Include ONLY criteria actually discussed — never invent. If none are \
                stated, output exactly NONE and nothing else.
                """),
                .init(role: "user", content: clipped)
            ],
            temperature: 0.2,
            max_tokens: 400
        )
        let raw = try await send(requestBody, timeout: 40, source: "POC criteria").trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.uppercased() == "NONE" { return [] }
        return raw.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-*• \t")) }
            .filter { !$0.isEmpty && $0.uppercased() != "NONE" }
    }

    /// Extract sales intelligence from a meeting transcript: the objections /
    /// concerns the other side raised (pricing, security, timeline, adoption,
    /// authority, competition …) and any competitor / incumbent tools mentioned,
    /// each with the context it came up in. Returns a Markdown body with an
    /// `### Objections` and/or `### Competitors` sub-section, or "" when neither
    /// is present. Draws only from the transcript — never invents.
    func extractObjectionsAndCompetitors(transcript: String) async throws -> String {
        guard !apiKey.isEmpty else { throw GroqError.missingAPIKey }
        let clipped = String(Self.summarizableBody(transcript).prefix(20_000))
        let requestBody = ChatRequest(
            model: model,   // nuanced sales-signal reading — use the polishing model
            messages: [
                .init(role: "system", content: """
                You are a sales engineer's analyst. From this meeting transcript, extract TWO things \
                the account team needs — using ONLY what was actually said, never inventing:

                1. OBJECTIONS — concerns, hesitations, pushback, blockers, or risks the customer/prospect \
                raised (e.g. price, security/compliance, timeline, integration effort, missing feature, \
                lack of buy-in, budget/authority). For each, note who raised it and, if stated, any \
                response or resolution given.
                2. COMPETITORS — any competing product, incumbent tool, vendor, or "we already use X" \
                mentioned, with the context (evaluating against us, currently in place, ruled out, …).

                Output GitHub Markdown in EXACTLY this shape, omitting a section entirely if it has no items:

                ### Objections
                - **<short label>** — <the objection in one line>. _Response:_ <response, or "none given">.

                ### Competitors
                - **<name>** — <context in one line>.

                No preamble, no other headings, no "N/A" filler. If NEITHER objections nor competitors \
                are present, output exactly NONE and nothing else.
                """),
                .init(role: "user", content: clipped)
            ],
            temperature: 0.2,
            max_tokens: 700
        )
        let raw = try await send(requestBody, timeout: 40, source: "Objections & competitors")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.uppercased() == "NONE" ? "" : raw
    }

    /// A short, human-readable title for a finished meeting (used as the note's
    /// front-matter `title:` in place of the timestamp). Cheap fast-model call.
    func meetingTitle(transcript: String) async throws -> String {
        guard !apiKey.isEmpty else { throw GroqError.missingAPIKey }
        let clipped = String(Self.summarizableBody(transcript).prefix(6_000))
        let requestBody = ChatRequest(
            model: fastModel,
            messages: [
                .init(role: "system", content: """
                Give this meeting a concise, specific title of 3–7 words — like an email subject. \
                Name the topic and, if clear, the party involved (e.g. "Acme SSO Migration Scoping", \
                "Q3 Pipeline Review"). No date, no quotes, no trailing punctuation, Title Case. \
                Output ONLY the title.
                """),
                .init(role: "user", content: clipped)
            ],
            temperature: 0.2,
            max_tokens: 24
        )
        let raw = try await send(requestBody, timeout: 15, role: .lightweight, source: "Meeting title")
        // One clean line, strip stray quotes/punctuation the model may add.
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\n").first?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'.")) ?? ""
    }

    /// The single structured artifact for a note — key points, Next Steps, and
    /// Action Items — cached once and reused for BOTH the notes-viewer summary
    /// and the relationship digest (which renders up to 5 of these). Returns the
    /// raw template with no blank lines; call `spacedBrief` when displaying.
    func noteBrief(text: String, forceRefresh: Bool = false) async throws -> String {
        let clipped = String(Self.summarizableBody(text).suffix(16_000))
        let requestBody = ChatRequest(
            model: model,   // polishing model — the brief drives quality-sensitive output; the fast model's low TPM chokes on a burst of per-note calls
            messages: [
                .init(role: "system", content: """
                Summarize ONE note into EXACTLY this template, with NO blank lines and every bullet starting with "- ":
                - 3–6 summary bullets (key points and decisions)
                Next Steps
                - top 2–3 upcoming steps (use "- None" if there are none)
                Action Items
                - top 2–3 open action items, with " — @owner" and "(due: …)" only when stated (use "- None" if there are none)
                Do NOT output any title or heading. Keep the literal labels "Next Steps" and "Action Items" on their own lines (no bullet, no colon). Draw only from this note — never invent. Output only the template, nothing else.
                """),
                .init(role: "user", content: clipped)
            ],
            temperature: 0.3,
            max_tokens: 600
        )
        // No source footer — the brief is composed into a strict template and
        // may be assembled per-meeting; a footer would break the block.
        return try await generateCached(
            kind: .brief, source: clipped, version: Self.briefPromptVersion,
            forceRefresh: forceRefresh, footer: false,
            groq: { try await self.send(requestBody, timeout: 40, source: "Note brief").trimmingCharacters(in: .whitespacesAndNewlines) },
            apple: { await AppleIntelligence.noteBrief(text: clipped) })
    }

    /// Insert a blank line before the "Next Steps" / "Action Items" labels so a
    /// brief reads clearly, regardless of the model's own spacing. Shared by the
    /// notes-viewer summary and the relationship digest so both look identical.
    static func spacedBrief(_ body: String) -> String {
        body.components(separatedBy: "\n").flatMap { line -> [String] in
            let t = line.trimmingCharacters(in: .whitespaces)
            return (t == "Next Steps" || t == "Action Items") ? ["", line] : [line]
        }.joined(separator: "\n")
    }

    // MARK: - Meeting Q&A

    /// Answer a question about a meeting transcript.
    func answer(question: String, transcript: String) async throws -> String {
        guard !apiKey.isEmpty else { throw GroqError.missingAPIKey }

        let clipped = String(transcript.suffix(AppSettings.shared.summaryContextChars))
        let requestBody = ChatRequest(
            model: model,
            messages: [
                .init(role: "system", content: """
                You answer questions about a meeting using ONLY the transcript provided.
                Be concise. Quote the relevant transcript line (with its timestamp) when helpful.
                If the transcript does not contain the answer, say so plainly — never guess.
                """),
                .init(role: "user", content: "Transcript:\n\n\(clipped)\n\nQuestion: \(question)")
            ],
            temperature: 0.2,
            max_tokens: 1024
        )
        return try await send(requestBody, timeout: 30, source: "Ask (meeting)")
    }

    // MARK: - Cross-Meeting Q&A

    /// Answer a question from excerpts drawn across many meetings.
    /// Excerpts are labeled "=== Meeting <name> ===" so answers can cite them.
    func answerAcrossMeetings(question: String, excerpts: String,
                              onDelta: (@Sendable (String) -> Void)? = nil) async throws -> String {
        guard !apiKey.isEmpty else { throw GroqError.missingAPIKey }

        let clipped = String(excerpts.suffix(AppSettings.shared.summaryContextChars))
        let requestBody = ChatRequest(
            model: model,
            messages: [
                .init(role: "system", content: """
                You answer questions using ONLY the provided meeting-transcript excerpts.
                Excerpts are grouped under "=== Meeting <date · time> ===" headers.
                Always cite which meeting(s) an answer comes from, e.g. "(2026-07-03 · 14:30)".
                Be concise. If the excerpts do not contain the answer, say so plainly — never guess.
                Different meetings are different conversations — do not blend them together.
                """),
                .init(role: "user", content: "Excerpts:\n\(clipped)\n\nQuestion: \(question)")
            ],
            temperature: 0.2,
            max_tokens: 1024
        )
        if let onDelta {
            return try await sendStreaming(requestBody, timeout: 30, source: "Ask (across meetings)", onDelta: onDelta)
        }
        return try await send(requestBody, timeout: 30, source: "Ask (across meetings)")
    }

    // MARK: - Agentic Ask

    /// Plan step for agentic Ask: decompose a question into 1–4 focused search
    /// queries so retrieval can gather evidence from several angles (e.g.
    /// "renewal risk with Acme" → "Acme renewal", "Acme objections", "Acme
    /// contract end date"). Returns the distinct queries; on any failure or a
    /// trivial question it returns `[question]` so the caller always has one.
    /// Uses the cheap fast model — this is a lightweight planning hop.
    func planQueries(question: String, history: String = "") async -> [String] {
        let fallback = [question]
        guard !apiKey.isEmpty else { return fallback }
        let framed = history.isEmpty ? question
            : "Conversation so far:\n\(history)\n\nLatest question: \(question)"
        let requestBody = ChatRequest(
            model: fastModel,
            messages: [
                .init(role: "system", content: """
                You plan a search over a knowledge base of meeting notes to answer the user's question.
                Break the question into 1–4 short, keyword-style search queries that together cover \
                everything needed to answer it — distinct angles, entities, and time frames, not \
                paraphrases of each other. A simple question needs just ONE query.
                Output ONLY the queries, one per line, no numbering, no quotes, no commentary.
                """),
                .init(role: "user", content: framed)
            ],
            temperature: 0.1,
            max_tokens: 120
        )
        guard let raw = try? await send(requestBody, timeout: 15, role: .lightweight, source: "Ask (plan)") else {
            return fallback
        }
        let queries = raw.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-*•0123456789. \t\"")) }
            .filter { !$0.isEmpty }
        return queries.isEmpty ? fallback : Array(queries.prefix(4))
    }

    /// Answer step for agentic Ask: like `answerAcrossMeetings`, but the context
    /// also carries a `=== Knowledge Base … ===` snapshot of the Catalog
    /// (accounts, opportunities, POC health, people). The model may draw on
    /// either source and is told to cite meetings by their header and to name
    /// the account/POC when the answer comes from the catalog snapshot.
    func answerAcrossKnowledge(question: String, excerpts: String, catalog: String,
                               onDelta: (@Sendable (String) -> Void)? = nil) async throws -> String {
        guard !apiKey.isEmpty else { throw GroqError.missingAPIKey }

        let clippedExcerpts = String(excerpts.suffix(AppSettings.shared.summaryContextChars))
        let context = catalog.isEmpty
            ? "Meeting excerpts:\n\(clippedExcerpts)"
            : "\(catalog)\n\nMeeting excerpts:\n\(clippedExcerpts)"
        let requestBody = ChatRequest(
            model: model,
            messages: [
                .init(role: "system", content: """
                You answer questions about the user's sales/work knowledge base using ONLY the context provided.
                The context has two parts: a "=== Knowledge Base … ===" snapshot of accounts, opportunities, \
                POC health and people; and meeting-transcript excerpts grouped under "=== Meeting <date · time> ===" headers.
                Use whichever part answers the question — structured facts (pipeline value, POC status, who someone is) \
                from the snapshot, specifics and quotes from the excerpts.
                Always cite your source: name the account/opportunity/POC for snapshot facts, and cite the meeting \
                (e.g. "(2026-07-03 · 14:30)") for excerpt facts. Different meetings are different conversations — don't blend them.
                Be concise. If the context doesn't contain the answer, say so plainly — never guess.
                """),
                .init(role: "user", content: "\(context)\n\nQuestion: \(question)")
            ],
            temperature: 0.2,
            max_tokens: 1024
        )
        if let onDelta {
            return try await sendStreaming(requestBody, timeout: 40, source: "Ask (knowledge base)", onDelta: onDelta)
        }
        return try await send(requestBody, timeout: 40, source: "Ask (knowledge base)")
    }

    // MARK: - Usage

    /// Record LLM token usage for the cost estimate in Stats.
    private static func recordUsage(_ result: ChatResponse) {
        guard let u = result.usage else { return }
        UsageStats.shared.recordChat(inputTokens: u.prompt_tokens, outputTokens: u.completion_tokens)
    }

    // MARK: - Live Brief

    /// A compact, mid-meeting brief: a few TL;DR bullets and the open action
    /// items so far. Kept short and cheap — called periodically while a meeting
    /// runs. Best-effort: throws on failure so the caller can keep the last good
    /// brief on screen.
    struct LiveBrief {
        let tldr: [String]
        let actions: [String]
        var isEmpty: Bool { tldr.isEmpty && actions.isEmpty }
    }

    func liveBrief(transcript: String, template: SummaryTemplate = .builtIn(.general)) async throws -> LiveBrief {
        guard !apiKey.isEmpty else { throw GroqError.missingAPIKey }
        // Recent context only — the running meeting, not the whole archive.
        let clipped = String(transcript.suffix(9_000))
        let body = ChatRequest(
            model: fastModel,
            messages: [
                .init(role: "system", content: """
                You keep a live brief of an ongoing meeting. From the transcript so far,
                respond with ONLY a JSON object, no prose:
                "tldr": up to 4 very short bullet strings capturing what's been discussed/decided so far,
                "actions": up to 5 short open action-item strings (append " — @name" when an owner is clear).
                Be concise and factual — use only what's in the transcript. Empty arrays are fine early on.
                """),
                .init(role: "user", content: clipped)
            ],
            temperature: 0.2,
            max_tokens: 400
        )
        let content = try await send(body, timeout: 20, role: .lightweight, source: "Live brief")
        return Self.parseLiveBrief(content)
    }

    static func parseLiveBrief(_ content: String) -> LiveBrief {
        guard let obj = firstJSONObject(in: content) else { return LiveBrief(tldr: [], actions: []) }
        func list(_ key: String, _ cap: Int) -> [String] {
            (obj[key] as? [Any] ?? []).compactMap { $0 as? String }
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .prefix(cap).map { $0 }
        }
        return LiveBrief(tldr: list("tldr", 4), actions: list("actions", 5))
    }

    // MARK: - Agenda status ("ask before it ends" + dynamic agenda)

    /// One update of agenda status, designed to be applied on top of prior
    /// state so the dynamic agenda is stable across ticks (see the caller).
    /// The model only *surfaces* topics — it never decides they're resolved
    /// (completion is always the user's to mark), so there's no resolved state here.
    struct AgendaStatus {
        /// Coverage per user-agenda item, aligned to the non-empty items in order.
        var userCovered: [Bool] = []
        /// Genuinely new substantive topics not already known (verbatim text).
        var newTopics: [String] = []
    }

    /// Stateful agenda update. Pass the user's agenda, the dynamic topics already
    /// discovered so far (`knownDynamic`, verbatim), and the transcript. The model
    /// (a) marks which user items were covered and (b) proposes only genuinely NEW
    /// substantive topics — real discussion themes worth a line in the minutes, not
    /// keywords. The caller keeps `knownDynamic` stable across calls and merges the
    /// result, so the list accumulates instead of churning. Best-effort: empty on failure.
    func agendaStatus(userAgenda: [String], knownDynamic: [String] = [],
                      transcript: String, preferFast: Bool = true) async -> AgendaStatus {
        let items = userAgenda.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !apiKey.isEmpty else { return AgendaStatus(userCovered: Array(repeating: false, count: items.count)) }

        // Discovery reads the whole meeting, not just the tail, so a topic from
        // early on isn't forgotten once it scrolls out of the recent window.
        let clipped = String(transcript.suffix(AppSettings.shared.summaryContextChars))
        let numberedAgenda = items.isEmpty
            ? "(none provided)"
            : items.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        let knownList = knownDynamic.isEmpty
            ? "(none yet)"
            : knownDynamic.map { "- \($0)" }.joined(separator: "\n")

        let body = ChatRequest(
            model: preferFast ? fastModel : model,
            messages: [
                .init(role: "system", content: """
                You maintain a meeting's agenda as it unfolds. Inputs: the user's numbered agenda
                (may be "(none provided)"), the discussion topics ALREADY identified so far, and the
                transcript. Respond with ONLY a JSON object, no prose:
                "covered": array of the user's item numbers (integers) meaningfully discussed (actually
                  addressed, not just name-dropped).
                "new_topics": at most 2 GENUINELY NEW substantive topics not already listed above —
                  each a real theme, decision, or open question worth a line in the minutes, phrased as
                  a short noun phrase (e.g. "Q3 hiring plan", not "hiring"). Array of short strings.
                Rules: Do NOT output keywords or single words. Do NOT restate or rephrase known topics as
                new ones. Prefer returning an empty "new_topics" over adding something marginal. Only use
                what's in the transcript.
                """),
                .init(role: "user", content: "AGENDA:\n\(numberedAgenda)\n\nKNOWN TOPICS:\n\(knownList)\n\nTRANSCRIPT:\n\(clipped)")
            ],
            temperature: 0,
            max_tokens: 220
        )
        guard let content = try? await send(body, timeout: 18, role: preferFast ? .lightweight : .summary, source: "Agenda coverage"),
              let obj = Self.firstJSONObject(in: content)
        else { return AgendaStatus(userCovered: Array(repeating: false, count: items.count)) }

        let coveredNums = Set((obj["covered"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue ?? Int("\($0)") })
        var status = AgendaStatus()
        status.userCovered = (0..<items.count).map { coveredNums.contains($0 + 1) }
        let knownSet = Set(knownDynamic.map { $0.lowercased() })
        // Tolerate both ["topic", …] and [{"topic": …}, …] shapes.
        for element in (obj["new_topics"] as? [Any] ?? []) {
            let raw = (element as? String) ?? ((element as? [String: Any])?["topic"] as? String)
            guard let topic = raw?.trimmingCharacters(in: .whitespaces),
                  topic.count > 2, !knownSet.contains(topic.lowercased()) else { continue }
            status.newTopics.append(topic)
            if status.newTopics.count >= 2 { break }
        }
        return status
    }

    // MARK: - Follow-up & Tags

    /// Draft an output document (MoM, follow-up email, status update, …) from a
    /// meeting's notes, shaped by `kind`. The output document type is separate
    /// from the meeting type. Each kind caches independently (its guidance is
    /// part of the key), so one meeting can produce several documents cheaply.
    /// Draft an output document from resolved guidance. Built-in `FollowUpKind`
    /// types and user-defined draft templates both flow through here via
    /// `DraftDoc.guidance`. Caches by guidance + content, so one meeting can
    /// produce several documents cheaply and each type stays independent.
    func draftDocument(transcript: String, guidance: String, forceRefresh: Bool = false) async throws -> String {
        try await draft(transcript: transcript, guidance: guidance, forceRefresh: forceRefresh)
    }

    /// Draft a follow-up shaped by the *meeting* template (recipient/tone vary
    /// by meeting type). Used for "Auto — match meeting type".
    func draftFollowUp(transcript: String, template: SummaryTemplate = .builtIn(.general), forceRefresh: Bool = false) async throws -> String {
        try await draft(transcript: transcript,
                        guidance: template.followUpGuidance + "\n\n" + Self.followUpFormat,
                        forceRefresh: forceRefresh)
    }

    /// Shared drafting core: build on the notes, obey `guidance`, cache by
    /// guidance + content so each document type has its own entry.
    private func draft(transcript: String, guidance: String, forceRefresh: Bool) async throws -> String {
        let clipped = String(Self.summarizableBody(transcript).suffix(AppSettings.shared.summaryContextChars))
        let cacheSource = guidance + "\u{0}" + clipped
        let body = ChatRequest(
            model: model,
            messages: [
                .init(role: "system", content: """
                You draft a document from a meeting's notes. Use ONLY what is in the
                notes below — which may already include a summary and action items;
                build on them and never contradict or invent facts.

                \(guidance)

                Keep it tight and skimmable. Attribute owners where identifiable.
                Output the document text only — no preamble or meta-commentary.
                """),
                .init(role: "user", content: "Notes:\n\n\(clipped)")
            ],
            temperature: 0.3,
            max_tokens: 800
        )
        return try await generateCached(
            kind: .followUp, source: cacheSource, version: Self.followUpPromptVersion,
            forceRefresh: forceRefresh, footer: true,
            groq: { try await self.send(body, timeout: 30, source: "Draft") },
            apple: { await AppleIntelligence.draftFollowUp(notes: clipped, guidance: guidance) })
    }

    /// Topic tags plus the named entities (people, customer, project) a meeting
    /// is about — for structured front-matter and richer search.
    struct MeetingMetadata {
        var topics: [String] = []      // lowercase, hyphenated subject tags
        var people: [String] = []      // participant/person names (proper-cased)
        var customer: String? = nil    // customer / client / org name
        var project: String? = nil     // project / product name

        var isEmpty: Bool {
            topics.isEmpty && people.isEmpty && customer == nil && project == nil
        }
    }

    /// Decode the first top-level JSON object embedded in an LLM reply,
    /// tolerating code fences / prose around it (slice from the first `{` to the
    /// last `}`). The one place the "find braces → JSONSerialization" idiom
    /// lives; every JSON-returning prompt parser routes through it.
    static func firstJSONObject(in content: String) -> [String: Any]? {
        guard let start = content.firstIndex(of: "{"),
              let end = content.lastIndex(of: "}"), start < end,
              let data = String(content[start...end]).data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Map a parsed JSON object's topic/entity keys onto `MeetingMetadata`.
    /// Reads keys from any object that also carries the combined-facts keys, so
    /// it backs `extractMeetingFacts`.
    static func parseMetadata(_ obj: [String: Any], includePeople: Bool) -> MeetingMetadata {
        func cleanTag(_ s: String) -> String {
            s.trimmingCharacters(in: .whitespaces).lowercased()
                .replacingOccurrences(of: " ", with: "-")
        }
        func str(_ key: String) -> String? {
            guard let v = obj[key] as? String else { return nil }
            let t = v.trimmingCharacters(in: .whitespaces)
            return (t.isEmpty || t.lowercased() == "null") ? nil : t
        }

        var m = MeetingMetadata()
        m.topics = (obj["topics"] as? [Any] ?? []).compactMap { $0 as? String }
            .map(cleanTag)
            .filter { !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } }
        if includePeople {
            m.people = (obj["people"] as? [Any] ?? []).compactMap { $0 as? String }
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        m.customer = str("customer")
        m.project = str("project")
        return m
    }

    // MARK: - Key-field extraction (per meeting type)

    /// One extracted field: the schema entry plus the value the model returned.
    struct ExtractedValue {
        let field: ExtractionField
        let value: String   // non-empty, trimmed
    }


    /// Map a parsed JSON object's keys onto the schema's fields, dropping
    /// empties. Category values are slugged; text values are trimmed.
    static func parseKeyFields(_ obj: [String: Any], fields: [ExtractionField]) -> [ExtractedValue] {
        fields.compactMap { field -> ExtractedValue? in
            guard let raw = obj[field.key] as? String else { return nil }
            var v = raw.trimmingCharacters(in: .whitespaces)
            guard !v.isEmpty, v.lowercased() != "null" else { return nil }
            if field.kind == .category {
                v = v.lowercased().replacingOccurrences(of: " ", with: "-")
            }
            return ExtractedValue(field: field, value: v)
        }
    }

    // MARK: - Combined meeting facts (title + metadata + key fields)

    /// Everything the meeting-end pass extracts as short structured values —
    /// pulled in ONE fast-model JSON call instead of three separate round-trips
    /// (`meetingTitle` + `extractMetadata` + `extractKeyFields`).
    struct MeetingFacts {
        var title = ""
        var metadata = MeetingMetadata()
        var keyFields: [ExtractedValue] = []
    }

    /// Extract the note's title, topic/entity metadata, and the meeting-type key
    /// fields in a single structured call. Each piece is requested only when
    /// asked for; all parsing is lenient and best-effort (an empty/failed call
    /// yields empty values, exactly like the three calls it replaces). A head +
    /// tail clip keeps both the opening (best for the title/topic) and the late
    /// decisions (best for fields) in view.
    func extractMeetingFacts(transcript: String, includeTitle: Bool,
                             includePeople: Bool, fields: [ExtractionField]) async -> MeetingFacts {
        guard !apiKey.isEmpty else { return MeetingFacts() }
        let body = Self.summarizableBody(transcript)
        let clip = body.count > 20_000
            ? String(body.prefix(6_000)) + "\n…\n" + String(body.suffix(14_000))
            : body

        var keys: [String] = []
        if includeTitle {
            keys.append(#""title": a concise 3-7 word Title-Case name for the meeting, like an email subject (name the topic and, if clear, the party) — no date, no quotes,"#)
        }
        keys.append(#""topics": 3-6 short lowercase hyphenated subject tags (e.g. ["budget-review","q3-roadmap"]),"#)
        keys.append(includePeople
            ? #""people": array of participant/person names mentioned (proper case, e.g. ["Priya Fernando"]),"#
            : #""people": [] (leave empty),"#)
        keys.append(#""customer": the customer/client/company name if this is about one, else null,"#)
        keys.append(fields.isEmpty
            ? #""project": the project or product name if one is central, else null."#
            : #""project": the project or product name if one is central, else null,"#)
        if !fields.isEmpty {
            let spec = fields.map { "  \"\($0.key)\": \($0.hint)" }.joined(separator: ",\n")
            keys.append("\"fields\": an object holding these keys (use \"\" for anything the transcript doesn't clearly state; for fields listing allowed values return exactly one, lowercase-hyphenated):\n{\n\(spec)\n}")
        }

        let request = ChatRequest(
            model: fastModel,
            messages: [
                .init(role: "system", content: """
                Analyze this meeting transcript. Respond with ONLY a JSON object, no prose, with keys:
                \(keys.joined(separator: "\n"))
                Use null (not "") for unknown top-level string fields. Do not invent names or values.
                """),
                .init(role: "user", content: clip)
            ],
            temperature: 0,
            max_tokens: 400
        )
        guard let content = try? await send(request, timeout: 20, role: .lightweight, source: "Meeting facts") else { return MeetingFacts() }
        return Self.parseMeetingFacts(content, includeTitle: includeTitle,
                                      includePeople: includePeople, fields: fields)
    }

    /// Parse the combined-facts JSON leniently (tolerates fences / stray text).
    static func parseMeetingFacts(_ content: String, includeTitle: Bool,
                                  includePeople: Bool, fields: [ExtractionField]) -> MeetingFacts {
        var facts = MeetingFacts()
        guard let obj = firstJSONObject(in: content) else { return facts }   // parse once
        facts.metadata = parseMetadata(obj, includePeople: includePeople)    // topics/people/customer/project
        if includeTitle, let t = obj["title"] as? String {
            facts.title = t.trimmingCharacters(in: CharacterSet(charactersIn: "\"'. \n\t"))
                .components(separatedBy: "\n").first ?? ""
        }
        if !fields.isEmpty, let sub = obj["fields"] as? [String: Any] {
            facts.keyFields = parseKeyFields(sub, fields: fields)
        }
        return facts
    }

    /// Shared chat request: sends (through the AIGate concurrency/rate-limit
    /// guard), records usage, returns the message content. `role` lets a
    /// model-availability fault refresh the catalog and retry once on the best
    /// available replacement for that kind of model.
    private func send(_ body: ChatRequest, timeout: TimeInterval,
                      role: ModelResolver.Role = .summary,
                      source: String = "Chat") async throws -> String {
        do {
            return try await perform(body, timeout: timeout, source: source)
        } catch {
            // A decommissioned/unknown model → refresh the live catalog, re-resolve
            // for this role, and retry once. Rate-limit/quota is NOT a model fault
            // (AIGate already backed off) — rethrow it untouched.
            guard ModelResolver.shared.classify(error) != nil else { throw error }
            await ModelResolver.shared.refresh(force: true)
            var retry = body
            let resolved = ModelResolver.shared.resolve(role, configured: body.model)
            guard resolved != body.model else { throw error }
            retry.model = resolved
            return try await perform(retry, timeout: timeout, source: source)
        }
    }

    private func perform(_ body: ChatRequest, timeout: TimeInterval, source: String) async throws -> String {
        var body = body
        // Reasoning models (gpt-oss) burn the token budget on hidden reasoning;
        // cap the effort so the visible answer still fits.
        if body.model.contains("gpt-oss"), body.reasoning_effort == nil { body.reasoning_effort = "low" }
        let payload = try JSONEncoder().encode(body)
        let url = URL(string: "\(baseURL)/chat/completions")!
        let key = apiKey
        let modelID = body.model

        return try await AIGate.shared.run(.chat) { [session] in
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = timeout
            request.httpBody = payload

            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw GroqError.invalidResponse }
            guard http.statusCode == 200 else {
                APIUsageLog.shared.recordChat(source: source, model: modelID,
                                              inputTokens: 0, outputTokens: 0, ok: false)
                let errBody = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                throw GroqError.apiError(statusCode: http.statusCode, message: String(errBody.prefix(200)))
            }
            let result = try JSONDecoder().decode(ChatResponse.self, from: data)
            Self.recordUsage(result)
            APIUsageLog.shared.recordChat(source: source, model: modelID,
                                          inputTokens: result.usage?.prompt_tokens ?? 0,
                                          outputTokens: result.usage?.completion_tokens ?? 0)
            // Reasoning models (e.g. gpt-oss) can leave `content` empty and put
            // the answer in `reasoning` — fall back to it so those models work.
            let msg = result.choices.first?.message
            let content = [msg?.content, msg?.reasoning]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            guard let content, !content.isEmpty else { throw GroqError.invalidResponse }
            return content
        }
    }

    // MARK: - Streaming

    /// Streaming counterpart of `send`: emits partial text through `onDelta` as
    /// tokens arrive and returns the full answer. A model-availability fault is
    /// retried once (safe — nothing has been emitted yet at that point).
    private func sendStreaming(_ body: ChatRequest, timeout: TimeInterval,
                               role: ModelResolver.Role = .summary, source: String = "Chat",
                               onDelta: @escaping @Sendable (String) -> Void) async throws -> String {
        do {
            return try await performStreaming(body, timeout: timeout, source: source, onDelta: onDelta)
        } catch {
            guard ModelResolver.shared.classify(error) != nil else { throw error }
            await ModelResolver.shared.refresh(force: true)
            var retry = body
            let resolved = ModelResolver.shared.resolve(role, configured: body.model)
            guard resolved != body.model else { throw error }
            retry.model = resolved
            return try await performStreaming(retry, timeout: timeout, source: source, onDelta: onDelta)
        }
    }

    private func performStreaming(_ body: ChatRequest, timeout: TimeInterval, source: String,
                                  onDelta: @escaping @Sendable (String) -> Void) async throws -> String {
        var body = body
        body.stream = true
        body.stream_options = .init(include_usage: true)
        if body.model.contains("gpt-oss"), body.reasoning_effort == nil { body.reasoning_effort = "low" }
        let payload = try JSONEncoder().encode(body)
        let url = URL(string: "\(baseURL)/chat/completions")!
        let key = apiKey
        let modelID = body.model

        return try await AIGate.shared.run(.chat) { [session] in
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            request.timeoutInterval = timeout
            request.httpBody = payload

            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw GroqError.invalidResponse }
            guard http.statusCode == 200 else {
                var errText = ""
                for try await line in bytes.lines { errText += line; if errText.count > 2000 { break } }
                APIUsageLog.shared.recordChat(source: source, model: modelID,
                                              inputTokens: 0, outputTokens: 0, ok: false)
                throw GroqError.apiError(statusCode: http.statusCode, message: String(errText.prefix(200)))
            }

            var full = ""
            var reasoning = ""
            var usage: ChatResponse.Usage?
            for try await line in bytes.lines {
                guard line.hasPrefix("data:") else { continue }
                let json = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
                if json == "[DONE]" { break }
                guard let data = json.data(using: .utf8),
                      let chunk = try? JSONDecoder().decode(ChatStreamChunk.self, from: data) else { continue }
                if let u = chunk.usage { usage = u }
                guard let delta = chunk.choices.first?.delta else { continue }
                // Stream the visible answer; hidden reasoning (gpt-oss) is kept
                // as a fallback but not surfaced token-by-token.
                if let c = delta.content, !c.isEmpty { full += c; onDelta(c) }
                else if let r = delta.reasoning, !r.isEmpty { reasoning += r }
            }

            if let usage {
                UsageStats.shared.recordChat(inputTokens: usage.prompt_tokens, outputTokens: usage.completion_tokens)
            }
            APIUsageLog.shared.recordChat(source: source, model: modelID,
                                          inputTokens: usage?.prompt_tokens ?? 0,
                                          outputTokens: usage?.completion_tokens ?? 0)
            let answer = (full.isEmpty ? reasoning : full).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !answer.isEmpty else { throw GroqError.invalidResponse }
            return answer
        }
    }

    // MARK: - Context-Aware Prompts

    /// Build a system prompt tailored to the active application.
    private func buildSystemPrompt(for context: AppContext) -> String {
        var basePrompt = """
        You are a dictation polisher. Your job is to clean up speech-to-text output.
        Fix grammar, punctuation, capitalization. Remove filler words (um, uh, like).
        Maintain the speaker's intent and meaning exactly.
        """

        let commandRules = AppSettings.shared.voiceCommandRules
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if AppSettings.shared.voiceCommandsEnabled, !commandRules.isEmpty {
            basePrompt += """


            Interpret spoken editing commands instead of transcribing them literally:
            \(commandRules)
            Only treat these as commands when clearly meant as commands, not as content \
            (e.g. "the meeting ended on a question mark" stays as words).
            """
        }

        // Resolve the writing style: per-app override → recognized app
        // category → the user's global default style. Each style's instruction
        // is user-editable in Settings.
        let contextPrompt = AppSettings.shared.resolvedDictationStyle(for: context).instruction

        return basePrompt + "\n\n" + contextPrompt
    }
}

// MARK: - Models

private struct ChatRequest: Codable {
    var model: String
    let messages: [ChatMessage]
    let temperature: Double
    let max_tokens: Int
    /// Only sent for reasoning models (gpt-oss) — keeps their hidden reasoning
    /// cheap so it doesn't consume the whole token budget before the answer.
    var reasoning_effort: String? = nil
    /// Set for the streaming (SSE) path; nil = normal buffered request.
    var stream: Bool? = nil
    /// Asks Groq to append a final usage chunk when streaming, so token cost is
    /// still recorded (the streamed choices carry no usage of their own).
    var stream_options: StreamOptions? = nil

    struct StreamOptions: Codable { let include_usage: Bool }
}

/// One Server-Sent-Events chunk from a streaming chat completion. `choices` is
/// empty on the trailing usage-only chunk.
private struct ChatStreamChunk: Codable {
    let choices: [Choice]
    let usage: ChatResponse.Usage?

    struct Choice: Codable { let delta: Delta? }
    struct Delta: Codable { let content: String?; let reasoning: String? }
}

private struct ChatMessage: Codable {
    let role: String
    let content: String
}

private struct ChatResponse: Codable {
    let choices: [Choice]
    let usage: Usage?

    struct Choice: Codable {
        let message: Message
    }

    /// Response message — `content` is optional and `reasoning` carries a
    /// reasoning model's output (which Groq returns in its own field).
    struct Message: Codable {
        let content: String?
        let reasoning: String?
    }

    struct Usage: Codable {
        let prompt_tokens: Int
        let completion_tokens: Int
    }
}
