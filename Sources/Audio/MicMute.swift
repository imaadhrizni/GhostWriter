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
    private let listeners = PropertyListeners()
    private var started = false
    private var generation = 0     // bumped per request, so a stale re-check stands down

    /// Per-device (suffixed with the device UID): each mic has its own level to restore.
    private static let savedVolumeKey = "audio.micMute.savedVolume"
    /// The level an unmute falls back to when no earlier volume was remembered.
    private static let fallbackVolume: Float32 = 0.7

    // MARK: Lifecycle

    /// Begin tracking the default input device. Idempotent.
    func start() {
        guard !started else { return }
        started = true
        listeners.add(CoreAudioDevice.system, CoreAudioDevice.address(kAudioHardwarePropertyDefaultInputDevice, scope: .global)) { [weak self] in
            self?.rebind()
        }
        // A microphone appeared (AirPods connected, a USB mic plugged in): match it to
        // the system's mute state before anything can use it.
        listeners.add(CoreAudioDevice.system, CoreAudioDevice.address(kAudioHardwarePropertyDevices, scope: .global)) { [weak self] in
            guard let self, self.isMuted else { return }
            self.applyToAllInputs(muted: true)
        }
        rebind()
    }

    /// Stop tracking (the mic keeps whatever state it is in).
    func stop() {
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
        if isMuted != muted {
            Log.audio.warning("🎙️ Asked to \(muted ? "mute" : "unmute") \(self.deviceName) but it still reports \(self.isMuted ? "muted" : "live") — retrying")
        } else {
            Log.audio.info("\(self.isMuted ? "🔇 Microphone muted" : "🎙️ Microphone unmuted") (\(self.deviceName))")
        }
        enforce(muted)
        return isMuted
    }

    /// Some devices — Bluetooth headsets especially — drop or reset a mute change when
    /// their input stream opens (the profile switch as a call starts). Look again a
    /// moment later and re-apply if the device no longer matches. A newer request
    /// supersedes this one.
    private func enforce(_ muted: Bool) {
        generation += 1
        let mine = generation
        Task { @MainActor [weak self] in
            for delay in [0.6, 1.5, 3.0] {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard let self, self.generation == mine else { return }
                self.refresh()
                if self.isMuted != muted {
                    Log.audio.warning("🎙️ \(self.deviceName) drifted back to \(self.isMuted ? "muted" : "live") — re-applying \(muted ? "mute" : "unmute")")
                    self.applyToAllInputs(muted: muted)
                    self.refresh()
                }
            }
        }
    }

    /// Set the mute state on each input device that has any control (default first).
    private func applyToAllInputs(muted: Bool) {
        for device in CoreAudioDevice.devices(withChannelsIn: .input) where Self.canMute(device) {
            Self.apply(muted: muted, to: device)
        }
    }

    /// Mute switch if the device has one, else its input volume (the prior level is
    /// remembered per device and restored on unmute).
    private static func apply(muted: Bool, to device: AudioObjectID) {
        let switches = CoreAudioDevice.settableElements(device, selector: kAudioDevicePropertyMute)
        if !switches.isEmpty {
            for el in switches { CoreAudioDevice.setU32(device, CoreAudioDevice.address(kAudioDevicePropertyMute, element: el), muted ? 1 : 0) }
            return
        }
        let sliders = CoreAudioDevice.settableElements(device, selector: kAudioDevicePropertyVolumeScalar)
        guard !sliders.isEmpty else { return }
        let key = "\(savedVolumeKey).\(CoreAudioDevice.uid(of: device))"
        if muted {
            if let v = CoreAudioDevice.getF32(device, CoreAudioDevice.address(kAudioDevicePropertyVolumeScalar, element: sliders[0])), v > 0.001 {
                UserDefaults.standard.set(Double(v), forKey: key)
            }
        }
        let target: Float32 = muted ? 0
            : Float32(UserDefaults.standard.object(forKey: key) as? Double ?? Double(fallbackVolume))
        for el in sliders { CoreAudioDevice.setF32(device, CoreAudioDevice.address(kAudioDevicePropertyVolumeScalar, element: el), target) }
    }

    private static func canMute(_ device: AudioObjectID) -> Bool {
        !CoreAudioDevice.settableElements(device, selector: kAudioDevicePropertyMute).isEmpty
            || !CoreAudioDevice.settableElements(device, selector: kAudioDevicePropertyVolumeScalar).isEmpty
    }

    // MARK: Device tracking

    /// The default input changed (or first start): re-point the listeners at it.
    private func rebind() {
        let hadDevice = deviceID != kAudioObjectUnknown
        let wasMuted = isMuted
        // Drop per-device listeners, keep the system-object one.
        listeners.removeAll(except: CoreAudioDevice.system)

        deviceID = CoreAudioDevice.defaultDevice(.input)
        if deviceID != kAudioObjectUnknown {
            for el in [kAudioObjectPropertyElementMain, 1, 2] {
                for sel in [kAudioDevicePropertyMute, kAudioDevicePropertyVolumeScalar] {
                    let a = CoreAudioDevice.address(sel, element: el)
                    if CoreAudioDevice.has(deviceID, a) { listeners.add(deviceID, a) { [weak self] in self?.refresh() } }
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
        deviceName = CoreAudioDevice.name(of: deviceID)
        let switches = CoreAudioDevice.settableElements(deviceID, selector: kAudioDevicePropertyMute)
        let sliders = CoreAudioDevice.settableElements(deviceID, selector: kAudioDevicePropertyVolumeScalar)
        isSupported = !switches.isEmpty || !sliders.isEmpty
        if !switches.isEmpty {
            isMuted = switches.allSatisfy { CoreAudioDevice.getU32(deviceID, CoreAudioDevice.address(kAudioDevicePropertyMute, element: $0)) == 1 }
        } else if !sliders.isEmpty {
            isMuted = sliders.allSatisfy { (CoreAudioDevice.getF32(deviceID, CoreAudioDevice.address(kAudioDevicePropertyVolumeScalar, element: $0)) ?? 1) < 0.001 }
        } else {
            isMuted = false
        }
    }
}
