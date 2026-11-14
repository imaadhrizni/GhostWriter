import CoreAudio
import Foundation

// MARK: - Microphone Mute
//
// System-level mute of the default input device, so a hotkey can silence the mic
// for *every* app on the call (Zoom, Meet, Teams…) — not just GhostWriter. This
// also silences GhostWriter's own capture (your side isn't transcribed while
// muted), which is the point.
//
// Mechanism, in order of preference:
//   1. the device's hardware/driver mute switch (`kAudioDevicePropertyMute`) —
//      what the built-in mic and most USB devices expose;
//   2. failing that, the input volume driven to 0 (the previous level is
//      remembered and restored on unmute) — for devices with no mute switch.
// A device with neither (some Bluetooth headsets) is reported unsupported.
//
// Mute state is applied to **every** input device, not just the current default:
// a mic that is switched to later (AirPods connecting and taking over as the input)
// would otherwise be live while the one you muted sits silent. A device that
// appears or becomes the default while the system is muted is muted to match.
//
// State is read back from the device, never assumed, and a CoreAudio listener
// keeps `isMuted` honest when something else changes it (System Settings, another
// app, the device being unplugged or the default input switching).

@MainActor
final class MicMute: ObservableObject {

    static let shared = MicMute()

    /// Whether the current default input is muted (by us or anyone else).
    @Published private(set) var isMuted = false
    /// Display name of the default input device ("" when there is none).
    @Published private(set) var deviceName = ""
    /// Whether the default input can be muted at all.
    @Published private(set) var isSupported = false

    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var listeners: [(object: AudioObjectID, address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)] = []
    private var started = false

    /// Per-device (suffixed with the device UID): each mic has its own level to restore.
    private static let savedVolumeKey = "audio.micMute.savedVolume"
    /// The level an unmute falls back to when no earlier volume was remembered.
    private static let fallbackVolume: Float32 = 0.7

    // MARK: Lifecycle

    /// Begin tracking the default input device. Idempotent.
    func start() {
        guard !started else { return }
        started = true
        listen(AudioObjectID(kAudioObjectSystemObject), Self.address(kAudioHardwarePropertyDefaultInputDevice, global: true)) { [weak self] in
            self?.rebind()
        }
        // A microphone appeared (AirPods connected, a USB mic plugged in): match it to
        // the system's mute state before anything can use it.
        listen(AudioObjectID(kAudioObjectSystemObject), Self.address(kAudioHardwarePropertyDevices, global: true)) { [weak self] in
            guard let self, self.isMuted else { return }
            self.applyToAllInputs(muted: true)
        }
        rebind()
    }

    /// Stop tracking (the mic keeps whatever state it is in).
    func stop() {
        for l in listeners {
            var a = l.address
            AudioObjectRemovePropertyListenerBlock(l.object, &a, .main, l.block)
        }
        listeners.removeAll()
        started = false
    }

    // MARK: Control

    /// Flip the mute. Returns the resulting state (unchanged if it couldn't be set).
    @discardableResult
    func toggle() -> Bool { setMuted(!isMuted) }

    /// Mute or unmute every input device (the default's resulting state is returned).
    @discardableResult
    func setMuted(_ muted: Bool) -> Bool {
        if !started { start() }
        guard deviceID != kAudioObjectUnknown else { return isMuted }
        guard Self.canMute(deviceID) else {
            Log.audio.warning("🔇 \(self.deviceName) has no mute or volume control — can't mute it")
            return isMuted
        }
        applyToAllInputs(muted: muted)
        refresh()
        Log.audio.info("\(self.isMuted ? "🔇 Microphone muted" : "🎙️ Microphone unmuted") (\(self.deviceName))")
        return isMuted
    }

    /// Set the mute state on each input device that has any control (default first).
    private func applyToAllInputs(muted: Bool) {
        for device in Self.inputDevices() where Self.canMute(device) {
            Self.apply(muted: muted, to: device)
        }
    }

    /// Mute switch if the device has one, else its input volume (the prior level is
    /// remembered per device and restored on unmute).
    private static func apply(muted: Bool, to device: AudioObjectID) {
        let switches = settableElements(device, selector: kAudioDevicePropertyMute)
        if !switches.isEmpty {
            for el in switches { setU32(device, address(kAudioDevicePropertyMute, element: el), muted ? 1 : 0) }
            return
        }
        let sliders = settableElements(device, selector: kAudioDevicePropertyVolumeScalar)
        guard !sliders.isEmpty else { return }
        let key = "\(savedVolumeKey).\(uid(of: device))"
        if muted {
            if let v = getF32(device, address(kAudioDevicePropertyVolumeScalar, element: sliders[0])), v > 0.001 {
                UserDefaults.standard.set(Double(v), forKey: key)
            }
        }
        let target: Float32 = muted ? 0
            : Float32(UserDefaults.standard.object(forKey: key) as? Double ?? Double(fallbackVolume))
        for el in sliders { setF32(device, address(kAudioDevicePropertyVolumeScalar, element: el), target) }
    }

    private static func canMute(_ device: AudioObjectID) -> Bool {
        !settableElements(device, selector: kAudioDevicePropertyMute).isEmpty
            || !settableElements(device, selector: kAudioDevicePropertyVolumeScalar).isEmpty
    }

    /// Every device with at least one input channel.
    private static func inputDevices() -> [AudioObjectID] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var a = address(kAudioHardwarePropertyDevices, global: true)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter { id in
            var c = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                               mScope: kAudioObjectPropertyScopeInput,
                                               mElement: kAudioObjectPropertyElementMain)
            var cs: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &c, 0, nil, &cs) == noErr, cs > 0 else { return false }
            let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(cs), alignment: 16)
            defer { raw.deallocate() }
            guard AudioObjectGetPropertyData(id, &c, 0, nil, &cs, raw) == noErr else { return false }
            let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
            return list.reduce(0) { $0 + Int($1.mNumberChannels) } > 0
        }
    }

    private static func uid(of id: AudioObjectID) -> String {
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                           mScope: kAudioObjectPropertyScopeGlobal,
                                           mElement: kAudioObjectPropertyElementMain)
        var ref: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &ref) { AudioObjectGetPropertyData(id, &a, 0, nil, &size, $0) }
        guard status == noErr, let s = ref?.takeRetainedValue() else { return String(id) }
        return s as String
    }

    // MARK: Device tracking

    /// The default input changed (or first start): re-point the listeners at it.
    private func rebind() {
        let hadDevice = deviceID != kAudioObjectUnknown
        let wasMuted = isMuted
        // Drop per-device listeners, keep the system-object one.
        let system = AudioObjectID(kAudioObjectSystemObject)
        for l in listeners where l.object != system {
            var a = l.address
            AudioObjectRemovePropertyListenerBlock(l.object, &a, .main, l.block)
        }
        listeners.removeAll { $0.object != system }

        deviceID = Self.getU32(system, Self.address(kAudioHardwarePropertyDefaultInputDevice, global: true)) ?? AudioObjectID(kAudioObjectUnknown)
        if deviceID != kAudioObjectUnknown {
            for el in [kAudioObjectPropertyElementMain, 1, 2] {
                for sel in [kAudioDevicePropertyMute, kAudioDevicePropertyVolumeScalar] {
                    let a = Self.address(sel, element: el)
                    var probe = a
                    if AudioObjectHasProperty(deviceID, &probe) { listen(deviceID, a) { [weak self] in self?.refresh() } }
                }
            }
        }
        refresh()
        // A different microphone took over as the default (AirPods connected…): keep
        // the system's state — if it was muted, the newcomer must not be live.
        if hadDevice, wasMuted, !isMuted, isSupported {
            Log.audio.info("🔇 Input switched to \(self.deviceName) while muted — muting it too")
            applyToAllInputs(muted: true)
            refresh()
        }
    }

    /// Re-read name, support and mute state from the device.
    private func refresh() {
        guard deviceID != kAudioObjectUnknown else {
            deviceName = ""; isSupported = false; isMuted = false
            return
        }
        deviceName = Self.name(of: deviceID)
        let switches = Self.settableElements(deviceID, selector: kAudioDevicePropertyMute)
        let sliders = Self.settableElements(deviceID, selector: kAudioDevicePropertyVolumeScalar)
        isSupported = !switches.isEmpty || !sliders.isEmpty
        if !switches.isEmpty {
            isMuted = switches.allSatisfy { Self.getU32(deviceID, Self.address(kAudioDevicePropertyMute, element: $0)) == 1 }
        } else if !sliders.isEmpty {
            isMuted = sliders.allSatisfy { (Self.getF32(deviceID, Self.address(kAudioDevicePropertyVolumeScalar, element: $0)) ?? 1) < 0.001 }
        } else {
            isMuted = false
        }
    }

    private func listen(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ action: @escaping @MainActor () -> Void) {
        var a = address
        // Delivered on the main queue, so it is safe to assume main-actor isolation.
        let block: AudioObjectPropertyListenerBlock = { _, _ in MainActor.assumeIsolated { action() } }
        if AudioObjectAddPropertyListenerBlock(object, &a, .main, block) == noErr {
            listeners.append((object, address, block))
        }
    }

    // MARK: CoreAudio helpers

    private static func address(_ selector: AudioObjectPropertySelector, element: UInt32 = kAudioObjectPropertyElementMain,
                                global: Bool = false) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: global ? kAudioObjectPropertyScopeGlobal : kAudioObjectPropertyScopeInput,
                                   mElement: element)
    }

    /// Elements (main, else channels 1–2) of the input scope on which `selector`
    /// exists and can be written.
    private static func settableElements(_ device: AudioObjectID, selector: AudioObjectPropertySelector) -> [UInt32] {
        func settable(_ el: UInt32) -> Bool {
            var a = address(selector, element: el)
            var writable = DarwinBoolean(false)
            return AudioObjectHasProperty(device, &a)
                && AudioObjectIsPropertySettable(device, &a, &writable) == noErr && writable.boolValue
        }
        if settable(kAudioObjectPropertyElementMain) { return [kAudioObjectPropertyElementMain] }
        return [1, 2].filter(settable)
    }

    private static func getU32(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress) -> UInt32? {
        var a = address, v: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr ? v : nil
    }

    private static func getF32(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Float32? {
        var a = address, v: Float32 = 0, size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr ? v : nil
    }

    private static func setU32(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress, _ value: UInt32) {
        var a = address, v = value
        AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v)
    }

    private static func setF32(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress, _ value: Float32) {
        var a = address, v = value
        AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
    }

    private static func name(of id: AudioObjectID) -> String {
        var a = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                           mScope: kAudioObjectPropertyScopeGlobal,
                                           mElement: kAudioObjectPropertyElementMain)
        var ref: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &ref) { AudioObjectGetPropertyData(id, &a, 0, nil, &size, $0) }
        guard status == noErr, let name = ref?.takeRetainedValue() else { return "" }
        return name as String
    }
}
