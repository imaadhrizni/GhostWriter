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

    func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - System Audio Recording

    /// Opens System Settings → Privacy & Security → Screen & System Audio Recording.
    /// This is where the "System Audio Recording Only" (CoreAudio process tap) permission lives.
    func openSystemAudioSettings() {
        // macOS 15+ groups the audio-recording toggle under the Screen Recording pane.
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
            "x-apple.systempreferences:com.apple.preference.security?Privacy",
        ]
        for string in candidates {
            if let url = URL(string: string), NSWorkspace.shared.open(url) {
                return
            }
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

    // MARK: - Reset

    /// Revokes all of GhostWriter's TCC permissions via `tccutil`, so macOS will
    /// prompt fresh next time each is requested. The running process keeps its
    /// current grants until relaunched, so callers should relaunch afterward.
    @discardableResult
    func resetAllPermissions() -> Bool {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.ghostwriter.dictation"
        // Microphone + Accessibility, plus the CoreAudio system-audio services
        // (AudioCapture is the process-tap service; ScreenCapture covers older paths).
        let services = ["Microphone", "Accessibility", "AudioCapture", "ScreenCapture"]

        var allOK = true
        for service in services {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            task.arguments = ["reset", service, bundleID]
            do {
                try task.run()
                task.waitUntilExit()
                if task.terminationStatus != 0 {
                    // Non-zero is expected when the app has no entry for that service yet.
                    print("ℹ️ tccutil reset \(service) exited \(task.terminationStatus)")
                }
            } catch {
                print("❌ tccutil reset \(service) failed: \(error.localizedDescription)")
                allOK = false
            }
        }
        return allOK
    }
}
