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
            sections.append("A section with the exact heading \"## Action Items\" containing a Markdown task list (\"- [ ] item\") with owners when identifiable (omit the section if none).")
        }

        let requestBody = ChatRequest(
            model: model,
            messages: [
                .init(role: "system", content: """
                You summarize meeting transcripts. Produce concise Markdown with exactly these sections:
                \(sections.joined(separator: "\n"))
                Rules:
                - Do not invent content that is not in the transcript.
                - Never output an empty section — omit a section entirely when there is nothing for it.
                - Never repeat a heading.
                - If the transcript has too little substantive discussion to summarize, output exactly NOT_ENOUGH_CONTENT and nothing else.
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
            model: model,
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

        // Per-app override from Settings wins over the automatic categorization.
        let category = AppSettings.shared.appProfileOverrides[context.bundleID.lowercased()]
            ?? context.category

        let contextPrompt: String
        switch category {
        case .messaging:
            contextPrompt = """
            The user is typing in a messaging app (\(context.appName)).
            Keep it casual and concise. Emojis are okay if the tone suggests them.
            Don't over-formalize. Short sentences are fine.
            """
        case .email:
            contextPrompt = """
            The user is composing an email in \(context.appName).
            Use professional tone. Proper paragraphs and punctuation.
            No emojis unless explicitly dictated.
            """
        case .code:
            contextPrompt = """
            The user is in a code editor (\(context.appName)).
            If the text sounds like a code comment, format it as a comment.
            If it sounds like documentation, format it as documentation.
            If it sounds like a commit message, format it concisely.
            Otherwise, just clean it up as plain text.
            """
        case .browser:
            contextPrompt = """
            The user is typing in a web browser (\(context.appName)).
            Clean, natural prose appropriate for web forms or messages.
            """
        case .notes:
            contextPrompt = """
            The user is in a notes/document app (\(context.appName)).
            Clean paragraphs with proper formatting. Maintain a natural writing style.
            """
        case .general:
            contextPrompt = """
            Clean up the text with standard professional English.
            """
        }

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

    struct Choice: Codable {
        let message: ChatMessage
    }
}
