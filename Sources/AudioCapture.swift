import AVFoundation
import Foundation

// MARK: - Audio Capture

/// Captures audio from the default input device using AVAudioEngine.
/// Outputs 16kHz Linear PCM (16-bit signed integer, mono) — Groq Whisper's native format.
///
/// Privacy guarantee: Audio NEVER touches the disk. All buffers are in-memory only.
final class AudioCapture {

    // MARK: - Callback

    /// Called with raw PCM data for each buffer. Data is 16kHz, 16-bit, mono.
    var onAudioBuffer: ((Data) -> Void)?

    // MARK: - Private State

    private let engine = AVAudioEngine()
    private var isRunning = false

    /// Target format for Groq Whisper: 16kHz, 16-bit signed integer, mono
    private lazy var targetFormat: AVAudioFormat = {
        AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!
    }()

    // MARK: - Public API

    /// Start capturing audio from the default microphone.
    func start() {
        guard !isRunning else { return }

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Install a tap on the input node
        // We'll transcode to our target format in the callback
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.processBuffer(buffer, from: inputFormat)
        }

        do {
            try engine.start()
            isRunning = true
            print("🎙️ Audio capture started — 16kHz PCM, memory-only")
        } catch {
            print("❌ Failed to start audio engine: \(error)")
        }
    }

    /// Stop capturing audio. Buffers are released from memory.
    func stop() {
        guard isRunning else { return }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        print("🎙️ Audio capture stopped")
    }

    // MARK: - Buffer Processing

    /// Convert the captured buffer to our target format (16kHz, 16-bit, mono)
    /// and emit as raw Data.
    private func processBuffer(_ buffer: AVAudioPCMBuffer, from sourceFormat: AVAudioFormat) {
        // Create a converter from input format to target format
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            print("❌ Cannot create audio converter")
            return
        }

        // Calculate the output frame count
        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputFrameCount
        ) else { return }

        var error: NSError?
        var inputConsumed = false

        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        if let error {
            print("❌ Audio conversion error: \(error)")
            return
        }

        // Extract raw Data from the PCM buffer
        guard let int16Data = outputBuffer.int16ChannelData else { return }
        let data = Data(
            bytes: int16Data[0],
            count: Int(outputBuffer.frameLength) * MemoryLayout<Int16>.size
        )

        onAudioBuffer?(data)
    }

    // MARK: - WAV Header Generation

    /// Create a valid WAV file in memory from raw PCM data.
    /// This is needed because Groq's Whisper API expects a WAV file upload.
    static func createWAV(from pcmData: Data, sampleRate: Int = 16000, channels: Int = 1, bitsPerSample: Int = 16) -> Data {
        var wav = Data()

        let byteRate = sampleRate * channels * (bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let dataSize = pcmData.count
        let chunkSize = 36 + dataSize

        // RIFF header
        wav.append(contentsOf: "RIFF".utf8)
        wav.append(contentsOf: withUnsafeBytes(of: UInt32(chunkSize).littleEndian) { Array($0) })
        wav.append(contentsOf: "WAVE".utf8)

        // fmt sub-chunk
        wav.append(contentsOf: "fmt ".utf8)
        wav.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) }) // sub-chunk size
        wav.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })  // PCM format
        wav.append(contentsOf: withUnsafeBytes(of: UInt16(channels).littleEndian) { Array($0) })
        wav.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { Array($0) })
        wav.append(contentsOf: withUnsafeBytes(of: UInt32(byteRate).littleEndian) { Array($0) })
        wav.append(contentsOf: withUnsafeBytes(of: UInt16(blockAlign).littleEndian) { Array($0) })
        wav.append(contentsOf: withUnsafeBytes(of: UInt16(bitsPerSample).littleEndian) { Array($0) })

        // data sub-chunk
        wav.append(contentsOf: "data".utf8)
        wav.append(contentsOf: withUnsafeBytes(of: UInt32(dataSize).littleEndian) { Array($0) })
        wav.append(pcmData)

        return wav
    }
}
