import Foundation
import AVFoundation

// MARK: - Audio Transcoder
//
// Prepares audio for the Groq Whisper upload *optimally*: Whisper works at
// 16 kHz mono internally, so anything larger is wasted upload bytes with no
// accuracy gain. Given decoded 16 kHz/mono/16-bit PCM (from
// `AudioFileImporter.decodePCM16k`), this produces the smallest Groq-accepted
// file it can — **Opus** (tiny, ~24 kbps) preferred, **FLAC** (lossless) as a
// fallback — and splits recordings that would still exceed Groq's per-request
// size limit into silence-aligned chunks the caller transcribes and stitches.

enum AudioTranscoder {

    /// Decoded-PCM constants (16 kHz, mono, 16-bit) shared across helpers.
    static let sampleRate = 16_000
    static let bytesPerSample = MemoryLayout<Int16>.size          // 2
    static let bytesPerSecond = 16_000 * MemoryLayout<Int16>.size // 32 000

    /// A compressed, Groq-accepted upload candidate written to a temp file.
    struct Encoded {
        let url: URL
        let mime: String
        let bytes: Int
    }

    // MARK: Encoding

    /// Ordered upload candidates for this PCM, smallest-first: Opus (ogg) then
    /// FLAC. The caller uploads them in order, falling through to the next if
    /// Groq rejects one (so a container Apple's encoder writes that Groq can't
    /// read self-heals to the lossless FLAC). Temp files are the caller's to
    /// delete — see `cleanUp`.
    static func uploadCandidates(pcm16k: Data) -> [Encoded] {
        guard let source = floatBuffer(from: pcm16k) else { return [] }
        var out: [Encoded] = []
        if let opus = encode(source, settings: [
            AVFormatIDKey: kAudioFormatOpus,
            AVSampleRateKey: sampleRate,          // Opus natively supports 16 kHz
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 24_000,
        ], ext: "ogg", mime: "audio/ogg") {
            out.append(opus)
        }
        if let flac = encode(source, settings: [
            AVFormatIDKey: kAudioFormatFLAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
        ], ext: "flac", mime: "audio/flac") {
            out.append(flac)
        }
        // Uncompressed WAV — always producible, always accepted. Only built when
        // both compressors are unavailable, so a missing platform encoder can't
        // block the upload; skipped otherwise to avoid writing a large temp file.
        if out.isEmpty {
            let wav = AudioCapture.createWAV(from: pcm16k)
            if let url = writeTemp(wav, ext: "wav") {
                out.append(Encoded(url: url, mime: "audio/wav", bytes: wav.count))
            }
        }
        return out
    }

    /// Best-effort delete of temp files produced by `uploadCandidates`.
    static func cleanUp(_ candidates: [Encoded]) {
        for c in candidates { try? FileManager.default.removeItem(at: c.url) }
    }

    /// Encode a float32/16 kHz/mono buffer to a temp file with `settings`.
    /// Returns nil (and cleans up) if the platform can't encode that format.
    private static func encode(_ source: AVAudioPCMBuffer, settings: [String: Any],
                               ext: String, mime: String) -> Encoded? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gw-upload-\(UUID().uuidString).\(ext)")
        do {
            // Force the processing (common) format to match our source buffer so
            // no manual sample-rate conversion is needed; Core Audio encodes on
            // write. A closure scope ensures the file flushes/closes before we
            // stat its size.
            try {
                let file = try AVAudioFile(forWriting: url, settings: settings,
                                           commonFormat: .pcmFormatFloat32, interleaved: false)
                try file.write(from: source)
            }()
        } catch {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int,
              size > 0 else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return Encoded(url: url, mime: mime, bytes: size)
    }

    /// Write raw bytes to a uniquely-named temp file with the given extension.
    private static func writeTemp(_ data: Data, ext: String) -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gw-upload-\(UUID().uuidString).\(ext)")
        do { try data.write(to: url); return url } catch { return nil }
    }

    /// Wrap 16 kHz/mono/16-bit PCM `Data` as a float32 buffer for encoding.
    private static func floatBuffer(from data: Data) -> AVAudioPCMBuffer? {
        guard !data.isEmpty,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate),
                                         channels: 1, interleaved: false) else { return nil }
        let frames = AVAudioFrameCount(data.count / bytesPerSample)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let dst = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frames
        data.withUnsafeBytes { raw in
            guard let src = raw.bindMemory(to: Int16.self).baseAddress else { return }
            for i in 0..<Int(frames) { dst[i] = Float(src[i]) / 32_768.0 }
        }
        return buffer
    }

    // MARK: Chunking

    /// Split 16 kHz/mono/16-bit PCM into segments no longer than `maxSeconds`,
    /// cutting at the quietest point near each boundary so a word isn't sliced
    /// mid-syllable. Returns the whole clip as a single element when it already
    /// fits. Used to keep each Groq request under its size limit; the caller
    /// transcribes each segment and joins the text in order.
    static func splitOnSilence(pcm16k: Data, maxSeconds: Double) -> [Data] {
        let total = pcm16k.count / bytesPerSample
        let maxSamples = Int(maxSeconds * Double(sampleRate))
        guard maxSamples > 0, total > maxSamples else { return [pcm16k] }

        let searchRadius = sampleRate * 3        // hunt ±3 s around each target cut
        let window = sampleRate / 10             // 100 ms RMS window

        return pcm16k.withUnsafeBytes { raw -> [Data] in
            let s = raw.bindMemory(to: Int16.self)
            var chunks: [Data] = []
            var start = 0
            while start < total {
                let target = start + maxSamples
                if target >= total {
                    chunks.append(pcm16k.subdata(in: (start * bytesPerSample)..<(total * bytesPerSample)))
                    break
                }
                // Scan for the lowest-energy window in the search band, but never
                // before the halfway mark so chunks can't collapse to nothing.
                var cut = target
                var lowest = Double.greatestFiniteMagnitude
                let lo = max(start + maxSamples / 2, target - searchRadius)
                let hi = min(total - window, target + searchRadius)
                var i = lo
                while i < hi {
                    var energy = 0.0
                    var j = i
                    let end = i + window
                    while j < end { let v = Double(s[j]); energy += v * v; j += 1 }
                    if energy < lowest { lowest = energy; cut = i + window / 2 }
                    i += window
                }
                chunks.append(pcm16k.subdata(in: (start * bytesPerSample)..<(cut * bytesPerSample)))
                start = cut
            }
            return chunks
        }
    }
}
