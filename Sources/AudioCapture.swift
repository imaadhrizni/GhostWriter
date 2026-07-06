import AVFoundation
import AudioToolbox
import CoreAudio
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

    // Recreated on every stop: a stopped AVAudioEngine still holds its input
    // HAL unit, which keeps the mic "in use" — on Bluetooth headsets (AirPods)
    // that pins them in the low-quality HFP call profile until the app quits.
    private var engine = AVAudioEngine()
    private var isRunning = false

    /// Cached converter — creating one per buffer is wasteful (~10×/sec).
    private var converter: AVAudioConverter?

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

        // Prefer the built-in mic over Bluetooth: capturing from AirPods forces
        // them into the HFP call profile (degraded output, volume shift). Pinning
        // the engine to the built-in mic keeps headphones in A2DP untouched.
        if AppSettings.shared.preferBuiltInMic,
           let builtIn = Self.builtInInputDeviceID(),
           let audioUnit = inputNode.audioUnit {
            var deviceID = builtIn
            let status = AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &deviceID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            if status != noErr {
                Log.audio.warning("⚠️ Could not pin built-in mic (\(status)) — using default input")
            }
        }

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
            Log.audio.debug("🎙️ Audio capture started — 16kHz PCM, memory-only")
        } catch {
            Log.audio.error("❌ Failed to start audio engine: \(error)")
        }
    }

    /// Stop capturing audio. Buffers are released from memory.
    func stop() {
        guard isRunning else { return }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()
        // Drop the engine entirely so the input HAL unit is truly released —
        // this lets Bluetooth headsets fall back from HFP to A2DP immediately.
        engine = AVAudioEngine()
        converter = nil
        isRunning = false
        Log.audio.debug("🎙️ Audio capture stopped")
    }

    // MARK: - Buffer Processing

    /// Convert the captured buffer to our target format (16kHz, 16-bit, mono)
    /// and emit as raw Data.
    private func processBuffer(_ buffer: AVAudioPCMBuffer, from sourceFormat: AVAudioFormat) {
        // Reuse the converter across buffers; rebuild only if the format changed
        // (e.g. AirPods switching profiles mid-capture).
        if converter == nil || converter?.inputFormat != sourceFormat {
            converter = AVAudioConverter(from: sourceFormat, to: targetFormat)
        }
        guard let converter else {
            Log.audio.error("❌ Cannot create audio converter")
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
            Log.audio.error("❌ Audio conversion error: \(error)")
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

    // MARK: - Device Discovery

    /// The built-in microphone's device ID, if present (nil on Macs without one).
    private static func builtInInputDeviceID() -> AudioDeviceID? {
        var prop = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain)

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &prop, 0, nil, &size) == noErr else { return nil }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &prop, 0, nil, &size, &devices) == noErr else { return nil }

        for device in devices {
            // Built-in transport only
            var transportProp = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyTransportType,
                mScope:    kAudioObjectPropertyScopeGlobal,
                mElement:  kAudioObjectPropertyElementMain)
            var transport: UInt32 = 0
            var tSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(device, &transportProp, 0, nil, &tSize, &transport) == noErr,
                  transport == kAudioDeviceTransportTypeBuiltIn else { continue }

            // Must have input streams (skip the built-in speaker)
            var streamsProp = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope:    kAudioObjectPropertyScopeInput,
                mElement:  kAudioObjectPropertyElementMain)
            var sSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(device, &streamsProp, 0, nil, &sSize) == noErr, sSize > 0 else { continue }

            return device
        }
        return nil
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
