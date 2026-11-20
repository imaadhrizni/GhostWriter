import CoreAudio
import Foundation

// MARK: - Speaker Status
//
// The Mac's output side — the default output device's volume and mute — for the
// menu-bar speaker icon: which speaker/headphones are active, how loud, muted or not,
// and a click to mute/unmute. Follows changes made anywhere (volume keys, Control
// Centre, another app, switching to AirPods) through CoreAudio listeners.
//
// Mute uses the device's mute switch when it has one (the built-in speakers do);
// otherwise the output volume is taken to 0 and the previous level restored on
// unmute (Bluetooth headphones are typically volume-only). A device with neither —
// some HDMI/DisplayPort outputs — is shown but reported unsupported.

@MainActor
final class SpeakerStatus: ObservableObject {

    static let shared = SpeakerStatus()

    /// Whether the default output is muted (switch set, or volume at zero).
    @Published private(set) var isMuted = false
    /// Output volume 0…1 (the mean of the channels), 0 when it can't be read.
    @Published private(set) var volume: Float = 0
    /// Display name of the default output device ("" when there is none).
    @Published private(set) var deviceName = ""
    /// Whether the output can be muted from here (a mute switch or a settable volume).
    @Published private(set) var isSupported = false

    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private let listeners = PropertyListeners()
    private var started = false

    /// Per-device (suffixed with the UID): the level to restore when unmuting by volume.
    private static let savedVolumeKey = "audio.speaker.savedVolume"
    private static let fallbackVolume: Float32 = 0.5

    // MARK: Lifecycle

    /// Begin tracking the default output device. Idempotent.
    func start() {
        guard !started else { return }
        started = true
        listeners.add(CoreAudioDevice.system, CoreAudioDevice.address(kAudioHardwarePropertyDefaultOutputDevice, scope: .global)) { [weak self] in
            self?.rebind()
        }
        rebind()
    }

    func stop() {
        listeners.removeAll()
        started = false
    }

    // MARK: Control

    /// Flip the mute. Returns the resulting state.
    @discardableResult
    func toggle() -> Bool { setMuted(!isMuted) }

    @discardableResult
    func setMuted(_ muted: Bool) -> Bool {
        if !started { start() }
        guard deviceID != kAudioObjectUnknown else { return isMuted }
        let switches = CoreAudioDevice.settableElements(deviceID, selector: kAudioDevicePropertyMute, scope: .output)
        if !switches.isEmpty {
            for el in switches { CoreAudioDevice.setU32(deviceID, CoreAudioDevice.address(kAudioDevicePropertyMute, scope: .output, element: el), muted ? 1 : 0) }
        } else {
            let sliders = CoreAudioDevice.settableElements(deviceID, selector: kAudioDevicePropertyVolumeScalar, scope: .output)
            guard !sliders.isEmpty else {
                Log.audio.warning("🔈 \(self.deviceName) has no mute or volume control — can't mute it")
                return isMuted
            }
            let key = "\(Self.savedVolumeKey).\(CoreAudioDevice.uid(of: deviceID))"
            if muted, volume > 0.001 { UserDefaults.standard.set(Double(volume), forKey: key) }
            let target = muted ? 0 : Float32(UserDefaults.standard.object(forKey: key) as? Double ?? Double(Self.fallbackVolume))
            for el in sliders { CoreAudioDevice.setF32(deviceID, CoreAudioDevice.address(kAudioDevicePropertyVolumeScalar, scope: .output, element: el), target) }
        }
        refresh()
        Log.audio.info("\(self.isMuted ? "🔇 Speaker muted" : "🔊 Speaker unmuted") (\(self.deviceName))")
        return isMuted
    }

    // MARK: Device tracking

    /// The default output changed (or first start): re-point the listeners at it.
    private func rebind() {
        listeners.removeAll(except: CoreAudioDevice.system)
        deviceID = CoreAudioDevice.defaultDevice(.output)
        if deviceID != kAudioObjectUnknown {
            for el in [kAudioObjectPropertyElementMain, 1, 2] {
                for sel in [kAudioDevicePropertyMute, kAudioDevicePropertyVolumeScalar] {
                    let a = CoreAudioDevice.address(sel, scope: .output, element: el)
                    if CoreAudioDevice.has(deviceID, a) { listeners.add(deviceID, a) { [weak self] in self?.refresh() } }
                }
            }
        }
        refresh()
    }

    /// Re-read name, volume, support and mute state from the device.
    private func refresh() {
        guard deviceID != kAudioObjectUnknown else {
            deviceName = ""; isSupported = false; isMuted = false; volume = 0
            return
        }
        deviceName = CoreAudioDevice.name(of: deviceID)

        // Volume: main element if present, else the mean of channels 1–2.
        let volumeElements = [kAudioObjectPropertyElementMain, 1, 2].filter {
            CoreAudioDevice.has(deviceID, CoreAudioDevice.address(kAudioDevicePropertyVolumeScalar, scope: .output, element: $0))
        }
        let levels = (volumeElements.first == kAudioObjectPropertyElementMain ? [kAudioObjectPropertyElementMain] : volumeElements)
            .compactMap { CoreAudioDevice.getF32(deviceID, CoreAudioDevice.address(kAudioDevicePropertyVolumeScalar, scope: .output, element: $0)) }
        volume = levels.isEmpty ? 0 : levels.reduce(0, +) / Float(levels.count)

        let switches = CoreAudioDevice.settableElements(deviceID, selector: kAudioDevicePropertyMute, scope: .output)
        let sliders = CoreAudioDevice.settableElements(deviceID, selector: kAudioDevicePropertyVolumeScalar, scope: .output)
        isSupported = !switches.isEmpty || !sliders.isEmpty
        if !switches.isEmpty {
            isMuted = switches.allSatisfy { CoreAudioDevice.getU32(deviceID, CoreAudioDevice.address(kAudioDevicePropertyMute, scope: .output, element: $0)) == 1 }
        } else {
            isMuted = !levels.isEmpty && volume < 0.001
        }
    }
}
