import Foundation

// MARK: - Groq Service

/// Handles communication with the Groq API for Whisper-v3 transcription.
/// Stage 1 of the Brain pipeline.
///
/// Endpoint: POST https://api.groq.com/openai/v1/audio/transcriptions
/// Model: whisper-large-v3
final class GroqService {

    // MARK: - Configuration

    /// Groq API key — read from Keychain (set once at launch, never stored in source).
    private var apiKey: String { KeychainService.groqAPIKey() ?? "" }

    private let baseURL = "https://api.groq.com/openai/v1"
    private let session = URLSession.shared

    // MARK: - Transcription

    /// Transcribe raw PCM audio data to text using Groq Whisper-v3.
    /// - Parameters:
    ///   - audioData: Raw 16kHz, 16-bit, mono PCM data
    ///   - context: Recent transcript text used to self-prime decoding, so
    ///     names/jargon stay consistent once they first appear. Optional.
    /// - Returns: Transcribed text
    func transcribe(audioData: Data, context: String = "") async throws -> String {
        guard !apiKey.isEmpty else {
            throw GroqError.missingAPIKey
        }

        // Convert PCM to WAV for the API
        let wavData = AudioCapture.createWAV(from: audioData)

        // Build multipart form data
        let boundary = UUID().uuidString
        var request = URLRequest(url: URL(string: "\(baseURL)/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        var body = Data()

        // Model parameter (user-configurable in Settings)
        body.appendMultipart(name: "model", value: AppSettings.shared.transcriptionModel, boundary: boundary)

        // Prompt hint: Whisper biases decoding toward text it has already
        // "seen". We combine the user's static glossary with rolling context —
        // the recent transcript — so names, acronyms, and jargon transcribe
        // consistently once they first appear. Self-priming needs no setup and
        // is the same for every user, which matters for a distributed build.
        let promptHint = Self.composePrompt(
            vocabulary: AppSettings.shared.vocabularyHint(), context: context)
        if !promptHint.isEmpty {
            body.appendMultipart(name: "prompt", value: promptHint, boundary: boundary)
        }

        // Language hint (optional — helps accuracy; user-configurable)
        let language = AppSettings.shared.transcriptionLanguage.trimmingCharacters(in: .whitespaces)
        if !language.isEmpty {
            body.appendMultipart(name: "language", value: language, boundary: boundary)
        }

        // Response format
        body.appendMultipart(name: "response_format", value: "json", boundary: boundary)

        // Audio file
        body.appendMultipartFile(name: "file", filename: "audio.wav", mimeType: "audio/wav", data: wavData, boundary: boundary)

        // Close boundary
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        // Send request
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GroqError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw GroqError.apiError(statusCode: httpResponse.statusCode, message: errorBody)
        }

        // Bill estimate: 16 kHz, 16-bit, mono PCM → 2 bytes/sample.
        let audioSeconds = Double(audioData.count) / 2.0 / 16_000.0
        UsageStats.shared.recordTranscription(audioSeconds: audioSeconds)

        // Parse response, then apply the user's find→replace rules
        let result = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
        return AppSettings.shared.applyReplacements(to: result.text)
    }

    /// Combine the static glossary with rolling transcript context into a single
    /// Whisper `prompt` hint. Whisper attends most to the END of the prompt, so
    /// the recent transcript goes last (closest to the new audio) and the
    /// glossary leads. Context is capped to its most recent slice to stay within
    /// Whisper's short prompt window and to limit the chance of the model
    /// echoing the primer back into the transcript.
    static func composePrompt(vocabulary: String, context: String) -> String {
        let vocab = vocabulary.trimmingCharacters(in: .whitespacesAndNewlines)
        let ctx = String(context.trimmingCharacters(in: .whitespacesAndNewlines).suffix(500))
        switch (vocab.isEmpty, ctx.isEmpty) {
        case (true, true):   return ""
        case (false, true):  return vocab
        case (true, false):  return ctx
        case (false, false): return vocab + "\n" + ctx
        }
    }
}

// MARK: - Models

private struct TranscriptionResponse: Codable {
    let text: String
}

// MARK: - Errors

enum GroqError: LocalizedError {
    case missingAPIKey
    case invalidResponse
    case apiError(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Groq API key not set. Add one via the menu bar → Set API Key…"
        case .invalidResponse:
            return "Invalid response from Groq API."
        case .apiError(let code, let message):
            return "Groq API error (\(code)): \(message)"
        }
    }
}

// MARK: - Data Helpers

extension Data {
    mutating func appendMultipart(name: String, value: String, boundary: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        append("\(value)\r\n".data(using: .utf8)!)
    }

    mutating func appendMultipartFile(name: String, filename: String, mimeType: String, data: Data, boundary: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        append(data)
        append("\r\n".data(using: .utf8)!)
    }
}
