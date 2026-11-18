import CoreAudio
import Foundation

// MARK: - CoreAudio device helpers
//
// The small property-reading/writing vocabulary shared by `MicMute` (input side) and
// `SpeakerStatus` (output side): addresses, settable elements, typed get/set, device
// names/UIDs, the device list, and a listener bag that cleans up after itself.
// Everything is stateless apart from `PropertyListeners`.

enum CoreAudioDevice {

    enum Scope {
        case global, input, output
        var raw: AudioObjectPropertyScope {
            switch self {
            case .global: return kAudioObjectPropertyScopeGlobal
            case .input:  return kAudioObjectPropertyScopeInput
            case .output: return kAudioObjectPropertyScopeOutput
            }
        }
    }

    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector, scope: Scope = .input,
                        element: UInt32 = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope.raw, mElement: element)
    }

    static func has(_ device: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var a = address
        return AudioObjectHasProperty(device, &a)
    }

    /// The current default input or output device (`kAudioObjectUnknown` if none).
    static func defaultDevice(_ scope: Scope) -> AudioObjectID {
        let selector = scope == .output ? kAudioHardwarePropertyDefaultOutputDevice : kAudioHardwarePropertyDefaultInputDevice
        return getU32(system, address(selector, scope: .global)) ?? AudioObjectID(kAudioObjectUnknown)
    }

    /// Elements (main, else channels 1–2) of `scope` on which `selector` exists and can be written.
    static func settableElements(_ device: AudioObjectID, selector: AudioObjectPropertySelector,
                                 scope: Scope = .input) -> [UInt32] {
        func settable(_ el: UInt32) -> Bool {
            var a = address(selector, scope: scope, element: el)
            var writable = DarwinBoolean(false)
            return AudioObjectHasProperty(device, &a)
                && AudioObjectIsPropertySettable(device, &a, &writable) == noErr && writable.boolValue
        }
        if settable(kAudioObjectPropertyElementMain) { return [kAudioObjectPropertyElementMain] }
        return [1, 2].filter(settable)
    }

    // MARK: Typed access

    static func getU32(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress) -> UInt32? {
        var a = address, v: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr ? v : nil
    }

    static func getF32(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Float32? {
        var a = address, v: Float32 = 0, size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr ? v : nil
    }

    static func setU32(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress, _ value: UInt32) {
        var a = address, v = value
        AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v)
    }

    static func setF32(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress, _ value: Float32) {
        var a = address, v = value
        AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
    }

    // MARK: Identity

    private static func string(_ selector: AudioObjectPropertySelector, of id: AudioObjectID) -> String? {
        var a = address(selector, scope: .global)
        var ref: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &ref) { AudioObjectGetPropertyData(id, &a, 0, nil, &size, $0) }
        guard status == noErr, let s = ref?.takeRetainedValue() else { return nil }
        return s as String
    }

    /// Display name ("MacBook Pro Microphone"), "" if unknown.
    static func name(of id: AudioObjectID) -> String { string(kAudioObjectPropertyName, of: id) ?? "" }

    /// Stable identifier, used to key per-device state; falls back to the numeric id.
    static func uid(of id: AudioObjectID) -> String { string(kAudioDevicePropertyDeviceUID, of: id) ?? String(id) }

    /// Every device with at least one channel in `scope` (`.input` or `.output`).
    static func devices(withChannelsIn scope: Scope) -> [AudioObjectID] {
        var a = address(kAudioHardwarePropertyDevices, scope: .global)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter { id in
            var c = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
            var cs: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &c, 0, nil, &cs) == noErr, cs > 0 else { return false }
            let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(cs), alignment: 16)
            defer { raw.deallocate() }
            guard AudioObjectGetPropertyData(id, &c, 0, nil, &cs, raw) == noErr else { return false }
            let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
            return list.reduce(0) { $0 + Int($1.mNumberChannels) } > 0
        }
    }
}

/// A set of CoreAudio property listeners that can be dropped together. Callbacks are
/// delivered on the main queue, so they run main-actor isolated.
@MainActor
final class PropertyListeners {
    private var entries: [(object: AudioObjectID, address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)] = []

    func add(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ action: @escaping @MainActor () -> Void) {
        var a = address
        let block: AudioObjectPropertyListenerBlock = { _, _ in MainActor.assumeIsolated { action() } }
        if AudioObjectAddPropertyListenerBlock(object, &a, .main, block) == noErr {
            entries.append((object, address, block))
        }
    }

    /// Remove every listener, or every one except those on `keep`.
    func removeAll(except keep: AudioObjectID? = nil) {
        for e in entries where e.object != keep {
            var a = e.address
            AudioObjectRemovePropertyListenerBlock(e.object, &a, .main, e.block)
        }
        entries.removeAll { $0.object != keep }
    }
}
