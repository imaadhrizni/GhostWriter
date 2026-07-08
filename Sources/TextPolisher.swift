import Foundation

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

        var request = URLRequest(url: URL(string: "\(baseURL)/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        request.httpBody = try JSONEncoder().encode(requestBody)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            // Graceful degradation: return raw text on error
            Log.api.warning("⚠️ Polishing failed — returning raw text")
            return rawText
        }

        let result = try JSONDecoder().decode(ChatResponse.self, from: data)
        recordUsage(result)
        return result.choices.first?.message.content ?? rawText
    }

    // MARK: - Meeting Summaries

    /// Summarize a meeting transcript. Sections come from the meeting
    /// template; Action Items is appended when enabled.
    func summarize(transcript: String,
                   template: SummaryTemplate = .builtIn(.general),
                   includeSummary: Bool = true,
                   includeActionItems: Bool = true) async throws -> String {
        guard !apiKey.isEmpty else { throw GroqError.missingAPIKey }
        guard includeSummary || includeActionItems else { throw GroqError.invalidResponse }

        // Keep well under context limits — a long meeting can exceed them.
        let clipped = String(transcript.suffix(24_000))

        var sections: [String] = []
        if includeSummary {
            sections.append(contentsOf: template.summarySections)
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
                - If the ENTIRE meeting has too little substantive discussion to summarize at all, output exactly NOT_ENOUGH_CONTENT and nothing else.
                """),
                .init(role: "user", content: "Summarize this meeting transcript:\n\n\(clipped)")
            ],
            temperature: 0.2,
            max_tokens: 1024
        )

        var request = URLRequest(url: URL(string: "\(baseURL)/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        request.httpBody = try JSONEncoder().encode(requestBody)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw GroqError.invalidResponse
        }
        let result = try JSONDecoder().decode(ChatResponse.self, from: data)
        recordUsage(result)
        guard let content = result.choices.first?.message.content, !content.isEmpty else {
            throw GroqError.invalidResponse
        }
        return content
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

        var request = URLRequest(url: URL(string: "\(baseURL)/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        request.httpBody = try JSONEncoder().encode(requestBody)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw GroqError.invalidResponse
        }
        let result = try JSONDecoder().decode(ChatResponse.self, from: data)
        recordUsage(result)
        guard let content = result.choices.first?.message.content, !content.isEmpty else {
            throw GroqError.invalidResponse
        }
        return content
    }

    // MARK: - Cross-Meeting Q&A

    /// Expand a natural-language question into search keywords (including
    /// likely synonyms) for retrieving relevant transcript excerpts.
    /// Falls back to the question's own significant words on any failure.
    func searchTerms(for question: String) async -> [String] {
        let fallback = question
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 4 }

        guard !apiKey.isEmpty else { return fallback }

        let requestBody = ChatRequest(
            model: fastModel,
            messages: [
                .init(role: "system", content: """
                Extract search keywords from the user's question for finding relevant lines in meeting transcripts.
                Include likely synonyms and related terms. Output ONLY a comma-separated list of 3-8 short keywords, nothing else.
                """),
                .init(role: "user", content: question)
            ],
            temperature: 0,
            max_tokens: 100
        )

        var request = URLRequest(url: URL(string: "\(baseURL)/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        request.httpBody = try? JSONEncoder().encode(requestBody)

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let result = try? JSONDecoder().decode(ChatResponse.self, from: data),
              let content = result.choices.first?.message.content else { return fallback }
        recordUsage(result)

        let terms = content
            .components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return terms.isEmpty ? fallback : terms
    }

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

        var request = URLRequest(url: URL(string: "\(baseURL)/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        request.httpBody = try JSONEncoder().encode(requestBody)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw GroqError.invalidResponse
        }
        let result = try JSONDecoder().decode(ChatResponse.self, from: data)
        recordUsage(result)
        guard let content = result.choices.first?.message.content, !content.isEmpty else {
            throw GroqError.invalidResponse
        }
        return content
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

    /// Draft a follow-up message recapping a meeting, shaped by its template
    /// (recipient, tone, and sections vary by meeting type). The notes may
    /// already contain a summary and action items — the draft builds on them.
    func draftFollowUp(transcript: String, template: SummaryTemplate = .builtIn(.general)) async throws -> String {
        guard !apiKey.isEmpty else { throw GroqError.missingAPIKey }
        let clipped = String(transcript.suffix(24_000))
        let body = ChatRequest(
            model: model,
            messages: [
                .init(role: "system", content: """
                You draft a follow-up from a meeting's notes. Use ONLY what is in the
                notes below — which may already include a summary and action items;
                build on them and never contradict or invent facts.

                \(template.followUpGuidance)

                Keep it tight and skimmable. Attribute owners where identifiable.
                If it's an email, start with a one-line subject. Output the follow-up
                text only — no preamble or meta-commentary.
                """),
                .init(role: "user", content: "Notes:\n\n\(clipped)")
            ],
            temperature: 0.3,
            max_tokens: 800
        )
        return try await send(body, timeout: 30)
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

    /// Shared chat request: sends, records usage, returns the message content.
    private func send(_ body: ChatRequest, timeout: TimeInterval) async throws -> String {
        var request = URLRequest(url: URL(string: "\(baseURL)/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw GroqError.invalidResponse
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
