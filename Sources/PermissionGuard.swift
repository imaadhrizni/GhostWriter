import AVFoundation
import AppKit
import CoreServices

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
        Log.permissions.debug("🎙️ Current Microphone Status: \(status.rawValue)")

        switch status {
        case .authorized:
            return true
        case .notDetermined:
            Log.permissions.debug("🎙️ Requesting Mic — Attempting to force prompt...")
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
            Log.permissions.info("🎤 Microphone permission denied in System Settings. Opening Settings...")
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

    /// Best-effort status of the System Audio Recording permission.
    /// There is no public query API for this TCC category, so we preflight via
    /// the TCC framework (same approach as AudioCap). Returns nil if unavailable.
    var hasSystemAudioPermission: Bool? {
        typealias PreflightFunc = @convention(c) (CFString, CFDictionary?) -> Int32
        guard let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW),
              let sym = dlsym(handle, "TCCAccessPreflight") else { return nil }
        let preflight = unsafeBitCast(sym, to: PreflightFunc.self)
        // 0 = granted, 1 = denied, 2 = prompt required (not yet determined)
        let result = preflight("kTCCServiceAudioCapture" as CFString, nil)
        dlclose(handle)
        return result == 0
    }

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
            Log.permissions.info("♿ Accessibility permission not granted — prompting user")
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

    func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Automation (Apple Events) status for the user's default browser, without
    /// prompting. Automation grants are per-target, so we report against the
    /// default browser as the representative case:
    ///   true  = granted, false = explicitly denied,
    ///   nil   = undetermined, browser not running, or unknown.
    func automationStatusForDefaultBrowser() -> Bool? {
        guard let browserID = defaultBrowserBundleID() else { return nil }
        let target = NSAppleEventDescriptor(bundleIdentifier: browserID)
        guard let desc = target.aeDesc else { return nil }
        // askUserIfNeeded: false → never prompts, just reports current status.
        let status = AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, false)
        switch status {
        case noErr:            return true    // authorized
        case OSStatus(-1743):  return false   // errAEEventNotPermitted (denied)
        default:               return nil     // -1744 undetermined / -600 not running
        }
    }

    private func defaultBrowserBundleID() -> String? {
        guard let url = URL(string: "https://example.com"),
              let appURL = NSWorkspace.shared.urlForApplication(toOpen: url) else { return nil }
        return Bundle(url: appURL)?.bundleIdentifier
    }

    // MARK: - Reset

    /// Revokes all of GhostWriter's TCC permissions via `tccutil`, so macOS will
    /// prompt fresh next time each is requested. The running process keeps its
    /// current grants until relaunched, so callers should relaunch afterward.
    @discardableResult
    func resetAllPermissions() -> Bool {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.ghostwriter.dictation"
        // Microphone + Accessibility, the CoreAudio system-audio services
        // (AudioCapture is the process-tap service; ScreenCapture covers older
        // paths), and AppleEvents (browser-tab Automation grants).
        let services = ["Microphone", "Accessibility", "AudioCapture", "ScreenCapture", "AppleEvents"]

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
                    Log.permissions.info("ℹ️ tccutil reset \(service) exited \(task.terminationStatus)")
                }
            } catch {
                Log.permissions.error("❌ tccutil reset \(service) failed: \(error.localizedDescription)")
                allOK = false
            }
        }
        return allOK
    }
}
