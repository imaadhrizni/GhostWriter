import Foundation
import Speech
import AVFoundation

// MARK: - Offline Transcriber
//
// Fallback when Groq is unreachable: Apple's on-device speech recognition.
// Lower accuracy than Whisper, but dictation keeps working with no network.

final class OfflineTranscriber {

    enum OfflineError: LocalizedError {
        case unavailable, notAuthorized, noResult
        var errorDescription: String? {
            switch self {
            case .unavailable:   return "On-device speech recognition is not available."
            case .notAuthorized: return "Speech recognition permission was not granted."
            case .noResult:      return "On-device recognition produced no text."
            }
        }
    }

    /// Transcribe 16kHz/16-bit/mono PCM data on-device, honoring the
    /// configured transcription language (falling back to en-US when the
    /// language has no on-device recognizer).
    func transcribe(audioData: Data) async throws -> String {
        let language = AppSettings.shared.transcriptionLanguage
            .trimmingCharacters(in: .whitespaces)
        let preferred = SFSpeechRecognizer(locale: Locale(identifier: language))
        let recognizer: SFSpeechRecognizer
        if let preferred, preferred.isAvailable, preferred.supportsOnDeviceRecognition {
            recognizer = preferred
        } else if let fallback = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
                  fallback.isAvailable, fallback.supportsOnDeviceRecognition {
            Log.api.warning("⚠️ No on-device recognizer for '\(language)' — falling back to en-US")
            recognizer = fallback
        } else {
            throw OfflineError.unavailable
        }

        guard await Self.requestAuthorization() else { throw OfflineError.notAuthorized }

        guard let buffer = Self.pcmBuffer(from: audioData) else { throw OfflineError.noResult }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.append(buffer)
        request.endAudio()

        return try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !resumed else { return }
                if let result, result.isFinal {
                    resumed = true
                    let text = result.bestTranscription.formattedString
                    if text.isEmpty {
                        continuation.resume(throwing: OfflineError.noResult)
                    } else {
                        continuation.resume(returning: AppSettings.shared.applyReplacements(to: text))
                    }
                } else if let error {
                    resumed = true
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Helpers

    private static func requestAuthorization() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        default:
            return false
        }
    }

    /// Wrap raw 16kHz Int16 mono PCM into an AVAudioPCMBuffer.
    private static func pcmBuffer(from data: Data) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 16000,
            channels: 1, interleaved: false) else { return nil }

        let frameCount = AVAudioFrameCount(data.count / MemoryLayout<Int16>.size)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channel = buffer.int16ChannelData else { return nil }

        buffer.frameLength = frameCount
        data.withUnsafeBytes { raw in
            guard let src = raw.bindMemory(to: Int16.self).baseAddress else { return }
            channel[0].update(from: src, count: Int(frameCount))
        }
        return buffer
    }
}
