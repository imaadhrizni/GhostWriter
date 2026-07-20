import Foundation
import AVFoundation

// MARK: - Audio Retainer
//
// Optional on-disk retention of a meeting's audio, so a note whose
// transcription failed can be regenerated from the original recording.
//
// GhostWriter's live capture is otherwise strictly in-memory. When retention is
// enabled the two 16 kHz mono Int16 PCM streams (mic = "you", system = "them")
// are appended to temporary raw files as they arrive, then mixed and encoded to
// a compact AAC `.m4a` under `<notes>/Audio/` when the meeting ends. Mixing is
// streamed in fixed-size chunks so memory stays bounded regardless of length.
//
// Thread-safe: the two `append*` calls arrive on audio threads and are
// serialised onto a private queue; `finish()`/`cancel()` are async.

// All mutable state is confined to the private `io` queue, so cross-actor
// captures (the finish() continuation) are safe.
final class AudioRetainer: @unchecked Sendable {

    private let sampleRate = 16_000.0
    private let baseName: String
    private let audioDir: URL
    private let tmpDir: URL
    private let youURL: URL          // mic stream
    private let themURL: URL         // system stream
    private let io = DispatchQueue(label: "com.ghostwriter.audioRetainer")

    private var youHandle: FileHandle?
    private var themHandle: FileHandle?
    private var started = false

    /// `baseName` is the note's filename stem (e.g. `Meeting_2026-07-20_…`); the
    /// recording is written into `audioDir` (already resolved to the dated
    /// `<notes>/Audio/yyyy/…` subfolder, mirroring the note's own organization).
    init(baseName: String, audioDir: URL) {
        self.baseName = baseName
        self.audioDir = audioDir
        self.tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gw-audio-\(baseName)", isDirectory: true)
        self.youURL = tmpDir.appendingPathComponent("you.pcm")
        self.themURL = tmpDir.appendingPathComponent("them.pcm")
    }

    /// Open the temp files. Safe to call once; a failure disables retention.
    func start() {
        io.sync {
            do {
                try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: youURL.path, contents: nil)
                FileManager.default.createFile(atPath: themURL.path, contents: nil)
                youHandle = try FileHandle(forWritingTo: youURL)
                themHandle = try FileHandle(forWritingTo: themURL)
                started = true
            } catch {
                Log.meeting.error("🎙️ Audio retention could not start: \(error.localizedDescription)")
                started = false
            }
        }
    }

    func appendMic(_ data: Data)    { append(data, to: youHandle) }
    func appendSystem(_ data: Data) { append(data, to: themHandle) }

    private func append(_ data: Data, to handle: FileHandle?) {
        guard started, !data.isEmpty else { return }
        io.async { try? handle?.write(contentsOf: data) }
    }

    /// Mix the two streams and encode to `<notes>/Audio/<baseName>.m4a`.
    /// Returns the finished file URL (nil if retention never started or nothing
    /// was recorded). Cleans up the temp files either way.
    func finish() async -> URL? {
        await withCheckedContinuation { cont in
            io.async { [self] in
                try? youHandle?.close(); try? themHandle?.close()
                youHandle = nil; themHandle = nil
                defer { try? FileManager.default.removeItem(at: tmpDir) }
                guard started else { cont.resume(returning: nil); return }
                let url = encodeMix()
                cont.resume(returning: url)
            }
        }
    }

    /// Abandon the recording (e.g. retention disabled mid-meeting) — closes and
    /// deletes the temp files without producing an output.
    func cancel() {
        io.async { [self] in
            try? youHandle?.close(); try? themHandle?.close()
            youHandle = nil; themHandle = nil
            started = false
            try? FileManager.default.removeItem(at: tmpDir)
        }
    }

    // MARK: Mix + encode

    /// Stream both raw Int16 files, sum sample-by-sample (with clipping), and
    /// write an AAC `.m4a`. Runs on `io`, so file handles are already closed.
    private func encodeMix() -> URL? {
        let fm = FileManager.default
        let youSize = (try? fm.attributesOfItem(atPath: youURL.path))?[.size] as? Int ?? 0
        let themSize = (try? fm.attributesOfItem(atPath: themURL.path))?[.size] as? Int ?? 0
        guard youSize + themSize > 0 else { return nil }

        guard let you = try? FileHandle(forReadingFrom: youURL),
              let them = try? FileHandle(forReadingFrom: themURL) else { return nil }
        defer { try? you.close(); try? them.close() }

        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return nil }
        try? fm.createDirectory(at: audioDir, withIntermediateDirectories: true)
        let outURL = audioDir.appendingPathComponent("\(baseName).m4a")
        try? fm.removeItem(at: outURL)   // overwrite any stale file
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]
        guard let file = try? AVAudioFile(forWriting: outURL, settings: settings) else { return nil }

        let chunkSamples = 16_000                       // ~1s per chunk
        let byteCount = chunkSamples * 2                // Int16
        while true {
            let a = (try? you.read(upToCount: byteCount)) ?? Data()
            let b = (try? them.read(upToCount: byteCount)) ?? Data()
            let n = max(a.count, b.count) / 2
            if n == 0 { break }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else { break }
            buffer.frameLength = AVAudioFrameCount(n)
            let out = buffer.floatChannelData![0]
            a.withUnsafeBytes { (ap: UnsafeRawBufferPointer) in
                b.withUnsafeBytes { (bp: UnsafeRawBufferPointer) in
                    let aI = ap.bindMemory(to: Int16.self)
                    let bI = bp.bindMemory(to: Int16.self)
                    for i in 0..<n {
                        let av = i < aI.count ? Int32(aI[i]) : 0
                        let bv = i < bI.count ? Int32(bI[i]) : 0
                        let sum = max(-32768, min(32767, av + bv))     // clip
                        out[i] = Float(sum) / 32768.0
                    }
                }
            }
            do { try file.write(from: buffer) } catch {
                Log.meeting.error("🎙️ Audio encode failed: \(error.localizedDescription)")
                return nil
            }
            if a.count < byteCount && b.count < byteCount { break }
        }
        Log.meeting.info("🎙️ Retained meeting audio → \(outURL.lastPathComponent)")
        return outURL
    }
}
