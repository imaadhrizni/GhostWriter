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
    /// - Parameter audioData: Raw 16kHz, 16-bit, mono PCM data
    /// - Returns: Transcribed text
    func transcribe(audioData: Data) async throws -> String {
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

        // Custom vocabulary: Whisper biases toward terms seen in the prompt —
        // names, acronyms, and jargon transcribe far more reliably.
        let vocabularyPrompt = AppSettings.shared.vocabularyPrompt
        if !vocabularyPrompt.isEmpty {
            body.appendMultipart(name: "prompt", value: vocabularyPrompt, boundary: boundary)
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

        // Parse response, then apply the user's find→replace rules
        let result = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
        return AppSettings.shared.applyReplacements(to: result.text)
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
