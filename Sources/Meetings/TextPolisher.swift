import Foundation

// MARK: - Output document types
//
// The KIND of document you draft from a meeting is a separate axis from the
// meeting's template: one meeting can yield minutes, a follow-up email, a
// status update, and more. Each kind carries its own drafting guidance and
// caches independently.

enum FollowUpKind: String, CaseIterable, Identifiable {
    case minutes, followUpEmail, statusUpdate, executiveSummary, actionItemList, thankYou
    case recap, decisionLog, talkingPoints, retrospective, interviewDebrief, faq, proposal, pocPlan

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
        case .interviewDebrief: return "Interview Debrief"
        case .faq:              return "FAQ"
        case .proposal:         return "Proposal / Next Steps"
        case .pocPlan:          return "POC Plan"
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
        case .interviewDebrief: return "person.text.rectangle"
        case .faq:              return "questionmark.circle"
        case .proposal:         return "doc.badge.gearshape"
        case .pocPlan:          return "flask"
        }
    }

    /// Category used to group the draft-document pickers and menus.
    enum Category: String, CaseIterable {
        case emailRecap, records, sales, reports, hiringRetro
        var title: String {
            switch self {
            case .emailRecap:  return "Email & Recap"
            case .records:     return "Records"
            case .sales:       return "Sales"
            case .reports:     return "Reports"
            case .hiringRetro: return "Hiring & Retro"
            }
        }
    }

    var category: Category {
        switch self {
        case .followUpEmail, .recap, .thankYou:        return .emailRecap
        case .minutes, .decisionLog, .actionItemList:  return .records
        case .proposal, .pocPlan, .talkingPoints:      return .sales
        case .statusUpdate, .executiveSummary, .faq:   return .reports
        case .interviewDebrief, .retrospective:        return .hiringRetro
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
        case .interviewDebrief: return "A hiring-panel debrief with a clear recommendation."
        case .faq:              return "The meeting's questions and answers as Q&A pairs."
        case .proposal:         return "A short proposal memo — context, recommendation, next steps."
        case .pocPlan:          return "A proof-of-concept plan — objective, success criteria, scope, timeline."
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
        case .interviewDebrief:
            return """
            Write an INTERVIEW DEBRIEF for a hiring panel, in Markdown: "## Summary" (2–3 sentences), "## Strengths" and "## Concerns" (bullets), and "## Recommendation" (one of Strong Hire / Hire / No Hire / Strong No Hire with a one-line justification). Evidence-based and specific to what was said.
            """
        case .faq:
            return """
            Turn the discussion into an FAQ — the questions raised and the answers given, as "**Q:** …" / "**A:** …" pairs, one blank line between pairs. Only include questions actually answered in the notes. No intro or outro.
            """
        case .proposal:
            return """
            Write a short PROPOSAL / NEXT-STEPS memo in Markdown: "## Context" (1–2 sentences on the situation), "## Proposal" (what's being recommended), and "## Next Steps" (a "- [ ] <step> — @<owner> (due: <date>)" checklist). Persuasive but grounded strictly in the notes.
            """
        case .pocPlan:
            return """
            Write a PROOF-OF-CONCEPT (POC) PLAN in Markdown for a technical evaluation, with "## " sections: Objective (what the POC must prove), Success Criteria (specific, measurable pass/fail items as a bullet list), Scope & Use Cases (what will and won't be tested), Environment & Prerequisites (access, data, accounts needed — from either side), Timeline & Milestones (phases with target dates), Roles (who owns what, on the vendor and customer side), and Risks / Open Questions. Draw strictly on the notes; where a detail wasn't discussed, add it as a bracketed placeholder like "[TBD: …]" rather than inventing it.
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

    private let baseURL = "https://api.groq.com/openai/v1"
    private let session = URLSession.shared
    private var model: String { AppSettings.shared.polishingModel }  // user-configurable in Settings
    /// Cheap/fast model for lightweight, high-frequency work (live brief,
    /// tagging, query expansion, agenda coverage) — keeps latency and cost low.
    private var fastModel: String { AppSettings.shared.fastModel }

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
            return try await send(requestBody, timeout: 15)
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
                   includeStructured: Bool = false) async throws -> String {
        guard !apiKey.isEmpty else { throw GroqError.missingAPIKey }
        guard includeSummary || includeActionItems || includeStructured else { throw GroqError.invalidResponse }

        // Long meetings exceed the context window. Rather than dropping the
        // opening (a tail-only clip), map-reduce: condense the whole meeting in
        // chunks first, so early decisions survive into the summary.
        let clipped = await condenseIfNeeded(transcript, cap: 24_000)

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
            sections.append("""
            A section with the exact heading "## Open Questions" listing, as Markdown bullets, questions left unresolved. Body "_None_" if none.
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
        return try await send(requestBody, timeout: 30)
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
            if let text = try? await send(body, timeout: 30) {
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
        let clipped = String(transcript.suffix(24_000))

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

        let content = try await send(requestBody, timeout: 30)
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == "NONE" ? "" : trimmed
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
            groq: { try await self.send(requestBody, timeout: 40).trimmingCharacters(in: .whitespacesAndNewlines) },
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

        let clipped = String(transcript.suffix(24_000))
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
        return try await send(requestBody, timeout: 30)
    }

    // MARK: - Cross-Meeting Q&A

    /// Answer a question from excerpts drawn across many meetings.
    /// Excerpts are labeled "=== Meeting <name> ===" so answers can cite them.
    func answerAcrossMeetings(question: String, excerpts: String) async throws -> String {
        guard !apiKey.isEmpty else { throw GroqError.missingAPIKey }

        let clipped = String(excerpts.suffix(24_000))
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
        return try await send(requestBody, timeout: 30)
    }

    // MARK: - Usage

    /// Record LLM token usage for the cost estimate in Stats.
    private func recordUsage(_ result: ChatResponse) {
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
        let content = try await send(body, timeout: 20)
        return Self.parseLiveBrief(content)
    }

    static func parseLiveBrief(_ content: String) -> LiveBrief {
        guard let start = content.firstIndex(of: "{"),
              let end = content.lastIndex(of: "}"),
              let data = String(content[start...end]).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return LiveBrief(tldr: [], actions: []) }
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
        let clipped = String(transcript.suffix(24_000))
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
        guard let content = try? await send(body, timeout: 18),
              let start = content.firstIndex(of: "{"), let end = content.lastIndex(of: "}"),
              let data = String(content[start...end]).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
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
        let clipped = String(Self.summarizableBody(transcript).suffix(24_000))
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
            groq: { try await self.send(body, timeout: 30) },
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

    /// Extract topic tags and named entities in a single call. `includePeople`
    /// is dropped when redaction is on, so participant names aren't harvested
    /// into metadata the user asked to keep private. Best-effort: returns an
    /// empty value on any failure.
    func extractMetadata(transcript: String, includePeople: Bool) async -> MeetingMetadata {
        guard !apiKey.isEmpty else { return MeetingMetadata() }
        let clipped = String(transcript.suffix(16_000))
        let peopleLine = includePeople
            ? #""people": array of participant/person names mentioned (proper case, e.g. ["Priya Fernando"]),"#
            : #""people": [] (leave empty),"#
        let body = ChatRequest(
            model: fastModel,
            messages: [
                .init(role: "system", content: """
                Identify what this meeting is about. Respond with ONLY a JSON object, no prose, with keys:
                "topics": 3-6 short lowercase hyphenated subject tags (e.g. ["budget-review","q3-roadmap"]),
                \(peopleLine)
                "customer": the customer/client/company name if this is about one, else null,
                "project": the project or product name if one is central, else null.
                Use null (not "") for unknown string fields. Do not invent names.
                """),
                .init(role: "user", content: clipped)
            ],
            temperature: 0,
            max_tokens: 200
        )
        guard let content = try? await send(body, timeout: 15) else { return MeetingMetadata() }
        return Self.parseMetadata(content, includePeople: includePeople)
    }

    /// Parse the model's JSON metadata leniently (tolerates code fences / stray text).
    static func parseMetadata(_ content: String, includePeople: Bool) -> MeetingMetadata {
        guard let start = content.firstIndex(of: "{"),
              let end = content.lastIndex(of: "}"),
              let data = String(content[start...end]).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return MeetingMetadata() }

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

    /// Extract the meeting-type's key fields as short values. Uses the fast
    /// model (this is a metadata footer, not a quality-sensitive draft) and
    /// returns only the fields the transcript actually supports. Best-effort:
    /// returns [] on any failure or when the schema is empty.
    func extractKeyFields(transcript: String, fields: [ExtractionField]) async -> [ExtractedValue] {
        guard !apiKey.isEmpty, !fields.isEmpty else { return [] }
        let clipped = String(transcript.suffix(16_000))
        let spec = fields.map { "\"\($0.key)\": \($0.hint)" }.joined(separator: ",\n")
        let body = ChatRequest(
            model: fastModel,
            messages: [
                .init(role: "system", content: """
                Extract these fields from the meeting transcript. Respond with ONLY a JSON object, no prose, with exactly these keys:
                \(spec)
                Rules: keep each value short (a few words, no sentences). Use "" (empty string) for anything the transcript does not clearly state — never guess. For fields listing allowed values, return exactly one of those values (lowercase, hyphenated) or "".
                """),
                .init(role: "user", content: clipped)
            ],
            temperature: 0,
            max_tokens: 300
        )
        guard let content = try? await send(body, timeout: 15) else { return [] }
        return Self.parseKeyFields(content, fields: fields)
    }

    /// Parse the model's JSON leniently into the schema's fields, dropping
    /// empties. Category values are slugged; text values are trimmed.
    static func parseKeyFields(_ content: String, fields: [ExtractionField]) -> [ExtractedValue] {
        guard let start = content.firstIndex(of: "{"),
              let end = content.lastIndex(of: "}"),
              let data = String(content[start...end]).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }

        return fields.compactMap { field -> ExtractedValue? in
            guard let raw = obj[field.key] as? String else { return nil }
            var v = raw.trimmingCharacters(in: .whitespaces)
            guard !v.isEmpty, v.lowercased() != "null" else { return nil }
            if field.kind == .category {
                v = v.lowercased().replacingOccurrences(of: " ", with: "-")
            }
            return ExtractedValue(field: field, value: v)
        }
    }

    /// Shared chat request: sends, records usage, returns the message content.
    private func send(_ body: ChatRequest, timeout: TimeInterval) async throws -> String {
        var request = URLRequest(url: URL(string: "\(baseURL)/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GroqError.invalidResponse }
        guard http.statusCode == 200 else {
            let body = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            throw GroqError.apiError(statusCode: http.statusCode, message: String(body.prefix(200)))
        }
        let result = try JSONDecoder().decode(ChatResponse.self, from: data)
        recordUsage(result)
        guard let content = result.choices.first?.message.content, !content.isEmpty else {
            throw GroqError.invalidResponse
        }
        return content
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
    let model: String
    let messages: [ChatMessage]
    let temperature: Double
    let max_tokens: Int
}

private struct ChatMessage: Codable {
    let role: String
    let content: String
}

private struct ChatResponse: Codable {
    let choices: [Choice]
    let usage: Usage?

    struct Choice: Codable {
        let message: ChatMessage
    }

    struct Usage: Codable {
        let prompt_tokens: Int
        let completion_tokens: Int
    }
}
