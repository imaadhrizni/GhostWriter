import Cocoa
import Carbon
import CoreGraphics

/// Manages the global hotkey (Right Option) using a CoreGraphics Event Tap.
/// This allows us to listen to keys even when the app is in the background or has no focus.
final class HotkeyManager {

    // MARK: - Constants

    /// Right Option key code on most Mac keyboards
    private static let rightOptionKeyCode: Int64 = 61

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

        print("⌨️ Sentinel active — listening for Right Option key")
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
        // We only care about flagsChanged (modifier keys)
        guard type == .flagsChanged else { return Unmanaged.passRetained(event) }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

        // Specifically looking for Right Option (keyCode 61)
        if keyCode == Self.rightOptionKeyCode {
            let isOptionPressed = flags.contains(.maskAlternate)

            if isOptionPressed && !isPressed {
                isPressed = true
                onKeyDown?()
            } else if !isOptionPressed && isPressed {
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
