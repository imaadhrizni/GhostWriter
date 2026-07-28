import Foundation
import AVFoundation

// MARK: - Audio File Importer

/// Helpers for importing an existing audio file (e.g. a voice note received via
/// a chat app) rather than live capture: format/MIME mapping, recording-date
/// and duration extraction from the file's own metadata, and a local decode to
/// 16 kHz mono PCM for the offline (on-device) transcription path.
///
/// The primary transcription path uploads the file to Groq as-is (see
/// `GroqService.transcribe(fileURL:…)`), which handles container formats Core
/// Audio can't read — notably ogg/opus. Local decode is only the fallback.
enum AudioFileImporter {

    /// Extensions we offer to import. Groq's Whisper endpoint accepts these
    /// containers directly; the ones Core Audio can also decode double as the
    /// offline fallback.
    static let acceptedExtensions: Set<String> = [
        "wav", "mp3", "m4a", "mp4", "aac", "aiff", "aif", "caf",
        "flac", "ogg", "oga", "opus", "webm"
    ]

    static func isAccepted(_ url: URL) -> Bool {
        acceptedExtensions.contains(url.pathExtension.lowercased())
    }

    /// MIME type for the multipart upload, by extension.
    static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "wav":            return "audio/wav"
        case "mp3":            return "audio/mpeg"
        case "m4a", "mp4", "aac": return "audio/mp4"
        case "aiff", "aif":    return "audio/aiff"
        case "caf":            return "audio/x-caf"
        case "flac":           return "audio/flac"
        case "ogg", "oga":     return "audio/ogg"
        case "opus":           return "audio/opus"
        case "webm":           return "audio/webm"
        default:               return "application/octet-stream"
        }
    }

    /// Best-effort recording date and duration from the file's own metadata.
    /// Prefers the media's embedded creation date (e.g. a Voice Memo's recording
    /// time), then the filesystem creation/modification date. Duration comes
    /// from the asset; nil if it can't be read (some ogg/opus files).
    static func metadata(of url: URL) async -> (date: Date, duration: TimeInterval?) {
        let asset = AVURLAsset(url: url)

        var duration: TimeInterval?
        if let cm = try? await asset.load(.duration) {
            let secs = CMTimeGetSeconds(cm)
            if secs.isFinite && secs > 0 { duration = secs }
        }

        // Embedded creation date, if the container carries one.
        var recorded: Date?
        if let items = try? await asset.load(.creationDate),
           let dateValue = try? await items.load(.dateValue) {
            recorded = dateValue
        }

        // Fall back to the file's own dates.
        if recorded == nil {
            let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            recorded = values?.creationDate ?? values?.contentModificationDate
        }

        return (recorded ?? Date(), duration)
    }

    /// Decode any Core Audio-readable file to the 16 kHz / mono / 16-bit PCM
    /// `Data` the offline transcriber and `AudioCapture.createWAV` expect.
    /// Throws for formats Core Audio can't open (e.g. ogg/opus) — the caller
    /// should treat that as "offline transcription unavailable for this file".
    static func decodePCM16k(from url: URL) throws -> Data {
        let file = try AVAudioFile(forReading: url)

        guard let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 16_000,
            channels: 1, interleaved: true) else {
            throw ImportError.decodeFailed
        }
        guard let converter = AVAudioConverter(from: file.processingFormat, to: outFormat) else {
            throw ImportError.decodeFailed
        }

        // Read the whole file into a source buffer.
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
              let inBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else {
            throw ImportError.decodeFailed
        }
        try file.read(into: inBuffer)

        // Convert to 16 kHz mono Int16, sized by the sample-rate ratio.
        let ratio = outFormat.sampleRate / file.processingFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(frameCount) * ratio) + 4096
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCapacity) else {
            throw ImportError.decodeFailed
        }

        var fed = false
        var conversionError: NSError?
        let status = converter.convert(to: outBuffer, error: &conversionError) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return inBuffer
        }
        if status == .error { throw conversionError ?? ImportError.decodeFailed }

        guard let channelData = outBuffer.int16ChannelData else { throw ImportError.decodeFailed }
        let byteCount = Int(outBuffer.frameLength) * MemoryLayout<Int16>.size
        return Data(bytes: channelData[0], count: byteCount)
    }

    enum ImportError: LocalizedError {
        case tooLarge(mb: Int, limit: Int)
        case unsupported(ext: String)
        case decodeFailed
        case emptyTranscript
        case transcriptionFailed(primary: String, fallback: String)

        var errorDescription: String? {
            switch self {
            case .tooLarge(let mb, let limit):
                return "That file is \(mb) MB — over the \(limit) MB import limit."
            case .unsupported(let ext):
                return "“.\(ext)” isn't a supported audio format."
            case .decodeFailed:
                return "Couldn't decode that audio file for on-device transcription."
            case .emptyTranscript:
                return "No speech was found in that audio."
            case .transcriptionFailed(let primary, let fallback):
                // Groq is the primary path; on-device is a best-effort rescue.
                // Lead with the primary failure (the actionable one) and note
                // that the fallback was tried too.
                return "Transcription failed: \(primary) (on-device fallback also failed: \(fallback))"
            }
        }
    }
}
