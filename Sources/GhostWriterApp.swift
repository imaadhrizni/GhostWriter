import SwiftUI
import AppKit

// MARK: - App Delegate

/// Manages the app lifecycle, permission checks, hotkey registration, and the floating overlay.
final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Properties

    private var statusItem: NSStatusItem?
    private var overlayPanel: NSPanel?
    private var overlayHostingView: NSHostingView<GlowOverlayView>?
    private var apiKeyWindowController: APIKeyWindowController?

    // Core services
    private let permissionGuard = PermissionGuard()
    private let hotkeyManager = HotkeyManager()
    private let audioCapture = AudioCapture()
    private let voiceActivityDetector = VoiceActivityDetector()
    private let groqService = GroqService()
    private let textPolisher = TextPolisher()
    private let appDetector = AppDetector()
    private let textInjector = TextInjector()

    // Shared state
    private let appState = AppState()

    // Audio buffer accumulator
    private var audioBuffer = Data()

    // Support logic
    private var hasPromptedForPermissions = false

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupOverlayPanel()
        setupHotkeyCallbacks()
        
        NotificationCenter.default.addObserver(self, selector: #selector(onAPIKeySaved), name: NSNotification.Name("APIKeySaved"), object: nil)

        // 1. Check for API Key first
        if KeychainService.groqAPIKey() == nil {
            print("🔑 API Key missing — showing setup window")
            showAPIKeyWindow()
        } else {
            // 2. If we have the key, proceed with normal initialization
            finishInitialization()
        }

        print("🎤 GhostWriter launched")
    }
    
    private func finishInitialization() {
        // Initial attempt to start hotkey (will fail if no perms)
        hotkeyManager.start()

        // Initial check for permissions (shows alert if missing)
        Task { @MainActor in
            await checkPermissions()
        }
    }
    
    @objc private func onAPIKeySaved() {
        finishInitialization()
    }
    
    @objc private func showAPIKeyWindow() {
        if apiKeyWindowController == nil {
            apiKeyWindowController = APIKeyWindowController()
        }
        apiKeyWindowController?.showAndActivate()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyManager.stop()
        audioCapture.stop()
        overlayPanel?.close()
    }

    // MARK: - Setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "waveform.circle.fill", accessibilityDescription: "GhostWriter")
            button.image?.size = NSSize(width: 18, height: 18)
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "GhostWriter v0.1.0", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        
        let apiKeyItem = NSMenuItem(title: "Set API Key…", action: #selector(showAPIKeyWindow), keyEquivalent: "k")
        apiKeyItem.target = self
        menu.addItem(apiKeyItem)

        let micItem = NSMenuItem(title: "Authorize Microphone…", action: #selector(manualMicRequest), keyEquivalent: "")
        micItem.target = self
        menu.addItem(micItem)

        let a11yItem = NSMenuItem(title: "Authorize Accessibility…", action: #selector(openPermissions), keyEquivalent: "")
        a11yItem.target = self
        menu.addItem(a11yItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit GhostWriter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem?.menu = menu
    }

    @objc private func manualMicRequest() {
        Task { @MainActor in
            await permissionGuard.requestMicrophonePermission()
        }
    }

    private func setupOverlayPanel() {
        let overlayView = GlowOverlayView(state: appState)
        let hostingView = NSHostingView(rootView: overlayView)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hostingView
        panel.isReleasedWhenClosed = false

        // Position at bottom-center of the main screen
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let panelSize = panel.frame.size
            let x = screenFrame.midX - panelSize.width / 2
            let y = screenFrame.minY + 60
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        self.overlayPanel = panel
        self.overlayHostingView = hostingView
    }

    // MARK: - Hotkey Callbacks

    private func setupHotkeyCallbacks() {
        hotkeyManager.onKeyDown = { [weak self] in
            self?.startRecording()
        }

        hotkeyManager.onKeyUp = { [weak self] in
            self?.stopRecordingAndProcess()
        }
    }

    // MARK: - Recording Flow

    private func startRecording() {
        guard permissionGuard.hasMicrophonePermission,
              permissionGuard.hasAccessibilityPermission else {
            print("⚠️ Missing permissions — cannot record")
            if !hasPromptedForPermissions {
                Task { @MainActor in await checkPermissions() }
            }
            return
        }

        audioBuffer = Data()
        appState.recordingState = .listening
        overlayPanel?.orderFront(nil)

        audioCapture.onAudioBuffer = { [weak self] buffer in
            guard let self else { return }
            let rms = self.voiceActivityDetector.calculateRMS(from: buffer)
            Task { @MainActor in self.appState.audioLevel = rms }
            self.audioBuffer.append(buffer)
        }

        audioCapture.start()
    }

    private func stopRecordingAndProcess() {
        audioCapture.stop()

        guard !audioBuffer.isEmpty else {
            appState.recordingState = .idle
            overlayPanel?.orderOut(nil)
            return
        }

        appState.recordingState = .processing
        let capturedAudio = audioBuffer
        audioBuffer = Data()

        Task {
            do {
                let rawText = try await groqService.transcribe(audioData: capturedAudio)
                guard !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    await MainActor.run {
                        appState.recordingState = .idle
                        overlayPanel?.orderOut(nil)
                    }
                    return
                }

                let activeApp = appDetector.currentApp()
                let polishedText = try await textPolisher.polish(rawText: rawText, appContext: activeApp)
                textInjector.inject(text: polishedText)

                await MainActor.run { appState.recordingState = .done }
                try? await Task.sleep(for: .milliseconds(500))
                await MainActor.run {
                    appState.recordingState = .idle
                    overlayPanel?.orderOut(nil)
                }
            } catch {
                print("❌ Pipeline error: \(error)")
                await MainActor.run { appState.recordingState = .error(error.localizedDescription) }
                try? await Task.sleep(for: .seconds(2))
                await MainActor.run {
                    appState.recordingState = .idle
                    overlayPanel?.orderOut(nil)
                }
            }
        }
    }

    // MARK: - Permissions

    @MainActor
    private func checkPermissions() async {
        let hasMic = await permissionGuard.requestMicrophonePermission()
        let hasA11y = permissionGuard.checkAccessibilityPermission()

        // If we have A11y now, try starting the hook again!
        if hasA11y {
            hotkeyManager.start()
        }

        if !hasMic || !hasA11y {
            guard !hasPromptedForPermissions else { return }
            hasPromptedForPermissions = true
            
            let alert = NSAlert()
            alert.messageText = "GhostWriter Needs Permissions"
            alert.informativeText = "Please enable Microphone and Accessibility in System Settings, then click 'I've Done It'."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "I've Done It")

            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                openPermissions()
            } else {
                // Retry starting the listener
                hotkeyManager.start()
            }
        }
    }

    @objc private func openPermissions() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}

// MARK: - App State

/// Observable state shared across the app — drives the GlowOverlay UI.
@Observable
final class AppState {
    var recordingState: RecordingState = .idle
    var audioLevel: Float = 0.0
}

// MARK: - Recording State

enum RecordingState: Equatable {
    case idle
    case listening
    case processing
    case done
    case error(String)

    static func == (lhs: RecordingState, rhs: RecordingState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.listening, .listening),
             (.processing, .processing), (.done, .done):
            return true
        case (.error(let a), .error(let b)):
            return a == b
        default:
            return false
        }
    }
}
