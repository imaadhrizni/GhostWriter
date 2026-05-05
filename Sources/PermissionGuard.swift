import AVFoundation
import AppKit

// MARK: - Permission Guard

/// Manages and checks microphone and accessibility permissions.
/// Privacy-first: we only request what we need, when we need it.
final class PermissionGuard {

    // MARK: - Computed State

    var hasMicrophonePermission: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    // MARK: - Microphone

    /// Requests microphone permission. Returns true if granted.
    func requestMicrophonePermission() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        print("🎙️ Current Microphone Status: \(status.rawValue)")

        switch status {
        case .authorized:
            return true
        case .notDetermined:
            print("🎙️ Requesting Mic — Attempting to force prompt...")
            await NSApplication.shared.activate(ignoringOtherApps: true)
            
            // First try the polite way
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if granted { return true }
            
            // Give macOS a moment to process before forcing
            try? await Task.sleep(for: .milliseconds(500))
            
            // Then try the "Brute Force" way — try to actually wake up the engine
            forceTriggerMicPrompt()
            
            // Wait a sec for the system to react
            try? await Task.sleep(for: .seconds(2))
            return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .denied, .restricted:
            print("🎤 Microphone permission denied in System Settings. Opening Settings...")
            openMicrophoneSettings()
            return false
        @unknown default:
            return false
        }
    }

    private func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    private func forceTriggerMicPrompt() {
        let engine = AVAudioEngine()
        let _ = engine.inputNode // Accessing inputNode triggers the system check
        try? engine.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            engine.stop()
        }
    }

    // MARK: - Accessibility

    /// Checks accessibility permission. If not granted, prompts the user.
    /// Note: There is no async API to request accessibility — macOS shows a system dialog.
    @discardableResult
    func checkAccessibilityPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)

        if !trusted {
            print("♿ Accessibility permission not granted — prompting user")
        }

        return trusted
    }

    // MARK: - Convenience

    /// Returns true only if both permissions are granted.
    var allPermissionsGranted: Bool {
        hasMicrophonePermission && hasAccessibilityPermission
    }

    /// Opens System Settings to the Privacy & Security → Accessibility pane.
    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
