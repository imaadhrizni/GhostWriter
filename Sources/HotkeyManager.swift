import Cocoa
import Carbon
import CoreGraphics

/// Manages the global hotkey (Right Option) using a CoreGraphics Event Tap.
/// This allows us to listen to keys even when the app is in the background or has no focus.
final class HotkeyManager {

    // MARK: - Configuration

    /// The push-to-talk key, read live from settings (default: Right Option).
    private var pttKey: PTTKey {
        PTTKey(rawValue: AppSettings.shared.pttKeyCode) ?? .rightOption
    }

    // MARK: - State

    fileprivate var eventTap: CFMachPort?
    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?

    private var isPressed = false

    // MARK: - Lifecycle

    @discardableResult
    func start() -> Bool {
        stop() // Reset any existing tap

        // We listen for flagsChanged events (Modifier keys like Option, Cmd, Shift)
        let eventMask = (1 << CGEventType.flagsChanged.rawValue)
        
        let selfPointer = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        
        // Modern Swift API for creating an event tap
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: HotkeyManager_hotkeyCallback,
            userInfo: selfPointer
        ) else {
            print("❌ Failed to create CGEventTap — check Accessibility permissions")
            return false
        }

        self.eventTap = tap
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        
        // Modern Swift API for enabling the tap
        CGEvent.tapEnable(tap: tap, enable: true)

        print("⌨️ Sentinel active — listening for \(pttKey.displayName)")
        return true
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
            print("⌨️ Sentinel stopped")
        }
    }

    // MARK: - Internal Handling

    fileprivate func handleEvent(_ event: CGEvent, type: CGEventType) -> Unmanaged<CGEvent>? {
        // macOS disables the tap if a callback is slow or on certain input events.
        // Re-enable it so the hotkey doesn't silently stop working.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passRetained(event)
        }

        // We only care about flagsChanged (modifier keys)
        guard type == .flagsChanged else { return Unmanaged.passRetained(event) }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

        // Match the configured push-to-talk key (default: Right Option, keyCode 61)
        let key = pttKey
        if keyCode == Int64(key.rawValue) {
            let isModifierPressed = flags.rawValue & key.flagMask != 0

            if isModifierPressed && !isPressed {
                isPressed = true
                onKeyDown?()
            } else if !isModifierPressed && isPressed {
                isPressed = false
                onKeyUp?()
            }
        }

        return Unmanaged.passRetained(event)
    }
}

// MARK: - C Callback

/// C-style callback required by CGEventTap.
/// Forwards the event to the HotkeyManager instance.
private func HotkeyManager_hotkeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon = refcon else { return Unmanaged.passRetained(event) }
    
    let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
    return manager.handleEvent(event, type: type)
}
