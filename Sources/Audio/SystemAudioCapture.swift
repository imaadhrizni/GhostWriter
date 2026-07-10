import CoreAudio
import AVFoundation
import Foundation

// MARK: - System Audio Capture (CoreAudio Process Tap, macOS 14.2+)
//
// Chain: CATapDescription → AudioHardwareCreateProcessTap → Aggregate Device →
//        AudioDeviceIOProc (direct CoreAudio callback, no AVAudioEngine) → onAudioBuffer
//
// Bypasses AVAudioEngine to avoid the mysterious "inputNode tap never fires" issue
// when using a custom aggregate device with an attached process tap.
// Uses only "System Audio Recording" permission, not "Screen & System Audio Recording".

final class SystemAudioCapture {

    var onAudioBuffer: ((Data) -> Void)?
    private(set) var isRunning = false

    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?
    /// Self pointer retained for the IOProc's clientData; released in stop().
    private var retainedSelf: UnsafeMutableRawPointer?

    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?

    // MARK: - Public API

    /// Triggers the macOS "System Audio Recording" TCC prompt.
    ///
    /// Merely creating a process tap does NOT prompt — tap creation needs no
    /// permission; only pulling audio does. So we run the full capture chain
    /// (tap → aggregate device → IOProc → start) briefly, which is what surfaces
    /// the NSAudioCaptureUsageDescription prompt, then tear it down again.
    /// Returns false only if the capture chain itself failed to start.
    @discardableResult
    func requestPermission() async -> Bool {
        guard #available(macOS 14.2, *) else { return false }
        guard !isRunning else { return true }  // already capturing → already prompted

        do {
            try await start()
            // Give TCC a moment to surface the prompt / the IOProc to run once.
            try? await Task.sleep(nanoseconds: 500_000_000)
            stop()
            return true
        } catch {
            Log.audio.info("ℹ️ System audio permission probe failed: \(error.localizedDescription)")
            stop()
            return false
        }
    }

    func start() async throws {
        guard !isRunning else { return }
        guard #available(macOS 14.2, *) else { throw CaptureError.unsupportedOS }

        // 1. Create a global mono tap (capture all processes, unmuted)
        let tap = CATapDescription()
        tap.isExclusive  = true   // tap ALL EXCEPT processes listed in .processes
        tap.processes    = []     // exclude none → capture everything
        tap.isMixdown    = true
        tap.isMono       = true   // mono — cleaner for speech transcription
        tap.muteBehavior = .unmuted
        tap.isPrivate    = true

        var tapObjectID: AudioObjectID = kAudioObjectUnknown
        let tapStatus = AudioHardwareCreateProcessTap(tap, &tapObjectID)
        guard tapStatus == noErr else { throw CaptureError.tapCreationFailed(tapStatus) }
        tapID = tapObjectID
        let tapUID = try readString(object: tapObjectID, selector: kAudioTapPropertyUID)
        Log.audio.debug("🎵 Tap created: \(tapUID)")

        // 2. Find built-in (non-Bluetooth) output device for clock stability
        guard let clockUID = builtInOutputDeviceUID() else {
            destroyTap(); throw CaptureError.noClockDevice
        }
        Log.audio.debug("🎵 Clock source: \(clockUID)")

        // 3. Create aggregate device
        //    kAudioAggregateDeviceTapAutoStartKey intentionally omitted:
        //    when set, the device blocks until a tapped app plays audio —
        //    we want the IOProc to start immediately (delivering silence when quiet).
        let aggUID  = "com.ghostwriter.agg.\(UUID().uuidString)"
        let aggDesc = [
            kAudioAggregateDeviceNameKey:         "GhostWriter Audio",
            kAudioAggregateDeviceUIDKey:           aggUID,
            kAudioAggregateDeviceIsPrivateKey:     1,
            kAudioAggregateDeviceTapListKey:       [[kAudioSubTapUIDKey: tapUID]],
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: clockUID]],
            kAudioAggregateDeviceClockDeviceKey:   clockUID,
            kAudioAggregateDeviceMainSubDeviceKey: clockUID,
        ] as CFDictionary

        var aggID: AudioObjectID = kAudioObjectUnknown
        let aggStatus = AudioHardwareCreateAggregateDevice(aggDesc, &aggID)
        guard aggStatus == noErr else {
            destroyTap(); throw CaptureError.aggregateDeviceFailed(aggStatus)
        }
        aggregateDeviceID = aggID

        // 4. Let HAL settle
        try await Task.sleep(nanoseconds: 300_000_000)

        // 5. Read the hardware stream format from the aggregate device
        let hwFormat = try aggregateInputFormat(deviceID: aggID)
        Log.audio.debug("🎵 Aggregate hardware format: \(hwFormat)")
        converter = AVAudioConverter(from: hwFormat, to: targetFormat)

        // 6. Register IOProc and start the device directly (no AVAudioEngine)
        let selfPtr = Unmanaged.passRetained(self).toOpaque()
        retainedSelf = selfPtr

        let procStatus = AudioDeviceCreateIOProcID(aggID, { _, _, inData, _, _, _, clientData in
            guard let ptr = clientData else { return noErr }
            let capture = Unmanaged<SystemAudioCapture>.fromOpaque(ptr).takeUnretainedValue()
            capture.handleIO(inData: inData)
            return noErr
        }, selfPtr, &ioProcID)

        guard procStatus == noErr, let ioProcID else {
            releaseRetainedSelf()
            destroyAggregate(); destroyTap()
            throw CaptureError.ioProcFailed(procStatus)
        }
        self.ioProcID = ioProcID

        let startStatus = AudioDeviceStart(aggID, ioProcID)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(aggID, ioProcID)
            self.ioProcID = nil
            releaseRetainedSelf()
            destroyAggregate(); destroyTap()
            throw CaptureError.startFailed(startStatus)
        }

        isRunning = true
        Log.audio.info("🎵 System audio capture started (CoreAudio IOProc)")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false

        if let proc = ioProcID, aggregateDeviceID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateDeviceID, proc)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, proc)
            ioProcID = nil
        }
        // Balance the passRetained from start() — only safe once the IOProc
        // is fully stopped and can no longer call back with the pointer.
        releaseRetainedSelf()
        destroyAggregate()
        destroyTap()
        converter = nil
        Log.audio.info("🎵 System audio capture stopped")
    }

    private func releaseRetainedSelf() {
        guard let ptr = retainedSelf else { return }
        retainedSelf = nil
        Unmanaged<SystemAudioCapture>.fromOpaque(ptr).release()
    }

    // MARK: - IOProc handler (called on the CoreAudio I/O thread)

    private func handleIO(inData: UnsafePointer<AudioBufferList>) {
        guard isRunning else { return }

        let abl = inData.pointee
        guard abl.mNumberBuffers > 0 else { return }

        let buf = abl.mBuffers          // first (and only, mono) buffer
        guard buf.mDataByteSize > 0, let data = buf.mData else { return }

        // Wrap raw bytes into AVAudioPCMBuffer for conversion
        guard let conv = converter,
              let hwFormat = conv.inputFormat as AVAudioFormat?,
              let pcmBuf = AVAudioPCMBuffer(pcmFormat: hwFormat,
                  frameCapacity: AVAudioFrameCount(buf.mDataByteSize) / hwFormat.streamDescription.pointee.mBytesPerFrame)
        else { return }

        pcmBuf.frameLength = pcmBuf.frameCapacity
        let dest = pcmBuf.mutableAudioBufferList.pointee.mBuffers
        memcpy(dest.mData, data, Int(buf.mDataByteSize))

        guard let converted = convert(pcmBuf, with: conv) else { return }
        onAudioBuffer?(converted)
    }

    // MARK: - Helpers

    private func aggregateInputFormat(deviceID: AudioObjectID) throws -> AVAudioFormat {
        // Get the stream configuration on the INPUT scope
        var prop = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope:    kAudioObjectPropertyScopeInput,
            mElement:  kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(deviceID, &prop, 0, nil, &size)

        // Get stream format from first input stream
        var asbd = AudioStreamBasicDescription()

        // Try getting format from the aggregate device directly
        var streamsProp = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope:    kAudioObjectPropertyScopeInput,
            mElement:  kAudioObjectPropertyElementMain)
        var streamsSize: UInt32 = 0
        AudioObjectGetPropertyDataSize(deviceID, &streamsProp, 0, nil, &streamsSize)
        let streamCount = Int(streamsSize) / MemoryLayout<AudioStreamID>.size
        Log.audio.debug("🎵 Aggregate input stream count: \(streamCount)")

        if streamCount > 0 {
            var streamIDs = [AudioStreamID](repeating: 0, count: streamCount)
            AudioObjectGetPropertyData(deviceID, &streamsProp, 0, nil, &streamsSize, &streamIDs)

            var streamFmtProp = AudioObjectPropertyAddress(
                mSelector: kAudioStreamPropertyVirtualFormat,
                mScope:    kAudioObjectPropertyScopeGlobal,
                mElement:  kAudioObjectPropertyElementMain)
            var streamFmtSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            let status = AudioObjectGetPropertyData(streamIDs[0], &streamFmtProp, 0, nil, &streamFmtSize, &asbd)
            if status == noErr, let fmt = AVAudioFormat(streamDescription: &asbd) {
                return fmt
            }
        }

        // Fallback: assume 1ch 48kHz Float32 (what we've seen reported)
        return AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
    }

    private func convert(_ buffer: AVAudioPCMBuffer, with conv: AVAudioConverter) -> Data? {
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let outFrames = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio))
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: max(outFrames, 1)) else { return nil }
        var inputConsumed = false; var error: NSError?
        conv.convert(to: out, error: &error) { _, status in
            if inputConsumed { status.pointee = .noDataNow; return nil }
            inputConsumed = true; status.pointee = .haveData; return buffer
        }
        guard error == nil, let ch = out.int16ChannelData else { return nil }
        return Data(bytes: ch[0], count: Int(out.frameLength) * MemoryLayout<Int16>.size)
    }

    private func builtInOutputDeviceUID() -> String? {
        var prop = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &prop, 0, nil, &size)
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &prop, 0, nil, &size, &ids)
        for id in ids {
            var tProp = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var transport: UInt32 = 0; var tSize = UInt32(MemoryLayout<UInt32>.size)
            AudioObjectGetPropertyData(id, &tProp, 0, nil, &tSize, &transport)
            guard transport == kAudioDeviceTransportTypeBuiltIn else { continue }
            var sProp = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            var sSize: UInt32 = 0
            AudioObjectGetPropertyDataSize(id, &sProp, 0, nil, &sSize)
            guard sSize > 0 else { continue }
            if let uid = try? readString(object: id, selector: kAudioDevicePropertyDeviceUID) { return uid }
        }
        return nil
    }

    private func readString(object: AudioObjectID, selector: AudioObjectPropertySelector) throws -> String {
        var prop = AudioObjectPropertyAddress(mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var cfStr: CFString? = nil; var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &cfStr) {
            AudioObjectGetPropertyData(object, &prop, 0, nil, &size, $0) }
        guard status == noErr, let s = cfStr else { throw CaptureError.propertyFailed(status) }
        return s as String
    }

    private func destroyTap() {
        guard tapID != kAudioObjectUnknown else { return }
        if #available(macOS 14.2, *) { AudioHardwareDestroyProcessTap(tapID) }
        tapID = kAudioObjectUnknown
    }
    private func destroyAggregate() {
        guard aggregateDeviceID != kAudioObjectUnknown else { return }
        AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
        aggregateDeviceID = kAudioObjectUnknown
    }

    // MARK: - Errors

    enum CaptureError: LocalizedError {
        case unsupportedOS, tapCreationFailed(OSStatus), aggregateDeviceFailed(OSStatus)
        case noClockDevice, ioProcFailed(OSStatus), startFailed(OSStatus), propertyFailed(OSStatus)
        var errorDescription: String? {
            switch self {
            case .unsupportedOS:                return "Requires macOS 14.2+"
            case .tapCreationFailed(let s):     return "Tap failed: \(s)"
            case .aggregateDeviceFailed(let s): return "Aggregate device failed: \(s)"
            case .noClockDevice:                return "No built-in audio device for clock"
            case .ioProcFailed(let s):          return "IOProc registration failed: \(s)"
            case .startFailed(let s):           return "Device start failed: \(s)"
            case .propertyFailed(let s):        return "Property read failed: \(s)"
            }
        }
    }
}
