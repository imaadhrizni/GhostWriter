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
    private var settingsWindowController: SettingsWindowController?
    private var meetingModeMenuItem: NSMenuItem?

    // Settings (UserDefaults-backed, live)
    private let settings = AppSettings.shared

    // Core services
    private let permissionGuard = PermissionGuard()
    private let hotkeyManager = HotkeyManager()
    private let audioCapture = AudioCapture()
    private let systemAudioCapture = SystemAudioCapture()
    private let voiceActivityDetector = VoiceActivityDetector()
    private let groqService = GroqService()
    private let textPolisher = TextPolisher()
    private let appDetector = AppDetector()
    private let textInjector = TextInjector()

    // Shared state
    private let appState = AppState()

    // PTT audio buffer
    private var audioBuffer = Data()

    // Meeting mode state — system audio (others), accessed on meetingQueue
    private let meetingQueue = DispatchQueue(label: "com.ghostwriter.meeting", qos: .userInteractive)
    private var meetingSpeechBuffer = Data()
    private var meetingLastVoiceTime: Date?
    private var meetingSegmentStart: Date?
    private var meetingSilenceDebounce: TimeInterval { settings.silenceDebounce }
    private var meetingMaxSegmentSeconds: TimeInterval { settings.maxSegmentSeconds }

    // Meeting mode state — microphone (self), accessed on micMeetingQueue
    private let micMeetingQueue = DispatchQueue(label: "com.ghostwriter.meeting.mic", qos: .userInteractive)
    private var micMeetingSpeechBuffer = Data()
    private var micMeetingLastVoiceTime: Date?
    private var micMeetingSegmentStart: Date?
    private let micCapture = AudioCapture()

    // Echo suppression (half-duplex): when using the built-in speaker instead of
    // headphones, the mic picks up the remote party's voice as acoustic echo and
    // mislabels it "You". We gate the mic while the speaker is (recently) active.
    private let echoGateLock = NSLock()
    private var speakerLastActiveTime: Date?
    private var echoGateWindow: TimeInterval { settings.echoGateWindow }  // mute mic for this long after speaker audio

    // Meeting notes
    private let meetingNotes = MeetingNotesWriter()
    private var meetingStartTime: Date?

    // Pause (⌃⌥P): gate transcription without ending the session.
    // Read from the audio queues, written on main — guarded by a lock.
    private let pauseLock = NSLock()
    private var meetingTranscriptionPaused = false
    private var isTranscriptionPaused: Bool {
        pauseLock.lock(); defer { pauseLock.unlock() }
        return meetingTranscriptionPaused
    }
    private func setTranscriptionPaused(_ value: Bool) {
        pauseLock.lock(); meetingTranscriptionPaused = value; pauseLock.unlock()
    }
    private var pauseMenuItem: NSMenuItem?

    // Support logic
    private var hasPromptedForPermissions = false

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupOverlayPanel()
        setupHotkeyCallbacks()

        NotificationCenter.default.addObserver(self, selector: #selector(onAPIKeySaved), name: NSNotification.Name("APIKeySaved"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(showAPIKeyWindow), name: .showAPIKeyWindow, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(onSettingsChanged), name: .settingsDidReset, object: nil)

        if KeychainService.groqAPIKey() == nil {
            print("🔑 API Key missing — showing setup window")
            showAPIKeyWindow()
        } else {
            finishInitialization()
        }

        print("🎤 GhostWriter launched")
    }

    private func finishInitialization() {
        // Note: hotkeyManager.start() is deliberately NOT called here — it creates a
        // CGEventTap which itself triggers the system Accessibility prompt. We let
        // checkPermissions() own the single, ordered prompt flow to avoid duplicates.
        Task { @MainActor in await checkPermissions() }
    }

    @objc private func onAPIKeySaved() {
        finishInitialization()
    }

    @objc private func showSettingsWindow() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController()
        }
        settingsWindowController?.showAndActivate()
    }

    @objc private func onSettingsChanged() {
        // Sliders write straight to UserDefaults and the capture callbacks read
        // AppSettings live, so a reset needs no re-wiring — this hook exists for
        // anything that caches a value at setup time.
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
        systemAudioCapture.stop()
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

        // ── Header ──────────────────────────────────────────────
        let titleItem = NSMenuItem(title: "GhostWriter v0.1.0", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)
        menu.addItem(NSMenuItem.separator())

        // ── Actions ─────────────────────────────────────────────
        // ⌃⌥M is a true global hotkey (handled by the CGEventTap); the key shown
        // here is display-only so users can discover it.
        let meetingItem = NSMenuItem(title: "Meeting Mode", action: #selector(toggleMeetingMode), keyEquivalent: "m")
        meetingItem.keyEquivalentModifierMask = [.control, .option]
        meetingItem.image = NSImage(systemSymbolName: "person.2.wave.2", accessibilityDescription: nil)
        meetingItem.target = self
        menu.addItem(meetingItem)
        self.meetingModeMenuItem = meetingItem

        let pauseItem = NSMenuItem(title: "Pause Transcription", action: #selector(togglePauseTranscription), keyEquivalent: "p")
        pauseItem.keyEquivalentModifierMask = [.control, .option]
        pauseItem.image = NSImage(systemSymbolName: "pause.circle", accessibilityDescription: nil)
        pauseItem.target = self
        menu.addItem(pauseItem)
        self.pauseMenuItem = pauseItem

        let notesItem = NSMenuItem(title: "Open Meeting Notes", action: #selector(openNotes), keyEquivalent: "n")
        notesItem.keyEquivalentModifierMask = [.control, .option]
        notesItem.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)
        notesItem.target = self
        menu.addItem(notesItem)

        menu.addItem(NSMenuItem.separator())

        // ── Configuration ───────────────────────────────────────
        // No key equivalents on window-opening items: this is a background app
        // (LSUIElement), so menu shortcuts only fire while the menu is open —
        // showing ⌘, / ⌘K would just mislead.
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettingsWindow), keyEquivalent: "")
        settingsItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        settingsItem.target = self
        menu.addItem(settingsItem)

        let apiKeyItem = NSMenuItem(title: "Set API Key…", action: #selector(showAPIKeyWindow), keyEquivalent: "")
        apiKeyItem.image = NSImage(systemSymbolName: "key", accessibilityDescription: nil)
        apiKeyItem.target = self
        menu.addItem(apiKeyItem)

        // Permissions grouped into a submenu to keep the top level clean
        let permissionsItem = NSMenuItem(title: "Permissions", action: nil, keyEquivalent: "")
        permissionsItem.image = NSImage(systemSymbolName: "lock.shield", accessibilityDescription: nil)
        let permissionsMenu = NSMenu(title: "Permissions")

        let micItem = NSMenuItem(title: "Authorize Microphone…", action: #selector(manualMicRequest), keyEquivalent: "")
        micItem.target = self
        permissionsMenu.addItem(micItem)

        let sysAudioItem = NSMenuItem(title: "Authorize System Audio Recording…", action: #selector(manualSystemAudioRequest), keyEquivalent: "")
        sysAudioItem.target = self
        permissionsMenu.addItem(sysAudioItem)

        let a11yItem = NSMenuItem(title: "Authorize Accessibility…", action: #selector(openPermissions), keyEquivalent: "")
        a11yItem.target = self
        permissionsMenu.addItem(a11yItem)

        permissionsMenu.addItem(NSMenuItem.separator())

        let resetItem = NSMenuItem(title: "Reset All Permissions…", action: #selector(resetPermissions), keyEquivalent: "")
        resetItem.target = self
        permissionsMenu.addItem(resetItem)

        permissionsItem.submenu = permissionsMenu
        menu.addItem(permissionsItem)

        menu.addItem(NSMenuItem.separator())

        // ── Quit ────────────────────────────────────────────────
        let quitItem = NSMenuItem(title: "Quit GhostWriter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem?.menu = menu
    }

    @objc private func manualMicRequest() {
        Task { @MainActor in
            // Fires the native prompt when the status is undetermined; awaits the result.
            _ = await permissionGuard.requestMicrophonePermission()
            // Always open the Settings pane afterward so the menu item is never a
            // silent no-op (e.g. when already authorized or previously denied).
            permissionGuard.openMicrophoneSettings()
        }
    }

    @objc private func manualSystemAudioRequest() {
        Task { @MainActor in
            // Running the capture chain surfaces the TCC prompt when undetermined.
            await systemAudioCapture.requestPermission()
            // Always open the Settings pane too, so the menu item is never a
            // silent no-op (e.g. when already granted or previously denied).
            permissionGuard.openSystemAudioSettings()
        }
    }

    @objc private func resetPermissions() {
        let alert = NSAlert()
        alert.messageText = "Reset all permissions?"
        alert.informativeText = "This revokes GhostWriter's Microphone, Accessibility, and System Audio Recording permissions, then relaunches the app so macOS can prompt you again."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset & Relaunch")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        permissionGuard.resetAllPermissions()
        relaunchApp()
    }

    private func relaunchApp() {
        // TCC resets only take effect for a fresh process, so start a new instance
        // and quit this one. The new launch runs checkPermissions() and re-prompts.
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }

    private func setupOverlayPanel() {
        let overlayView = GlowOverlayView(state: appState)
        let hostingView = NSHostingView(rootView: overlayView)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 180, height: 180),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true  // enabled for dragging when in meeting mode
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.contentView = hostingView
        panel.isReleasedWhenClosed = false

        positionOverlayPanel(panel)

        self.overlayPanel = panel
        self.overlayHostingView = hostingView
    }

    private func positionOverlayPanel(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let panelSize = panel.frame.size
        let x = screenFrame.midX - panelSize.width / 2
        let y = screenFrame.minY + 60
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: - Hotkey Callbacks

    private func setupHotkeyCallbacks() {
        hotkeyManager.onKeyDown = { [weak self] in
            self?.startRecording()
        }

        hotkeyManager.onKeyUp = { [weak self] in
            self?.stopRecordingAndProcess()
        }

        // ⌃⌥M — global Meeting Mode toggle (works while the app is in background)
        hotkeyManager.onMeetingModeHotkey = { [weak self] in
            self?.toggleMeetingMode()
        }

        // ⌃⌥N — open the live meeting notes file, or the notes folder when idle
        hotkeyManager.onOpenNotesHotkey = { [weak self] in
            self?.openNotes()
        }

        // ⌃⌥P — pause/resume meeting transcription (no-op outside meetings)
        hotkeyManager.onPauseMeetingHotkey = { [weak self] in
            self?.togglePauseTranscription()
        }

        // Esc — cancel an in-flight dictation without typing anything
        hotkeyManager.shouldCaptureEscape = { [weak self] in
            self?.appState.recordingState == .listening
        }
        hotkeyManager.onCancelDictation = { [weak self] in
            self?.cancelRecording()
        }
    }

    // MARK: - Notes & Pause Hotkeys

    /// ⌃⌥N: reveal the live meeting notes file, or the notes folder when idle.
    @objc private func openNotes() {
        if let file = meetingNotes.currentFilePath {
            NSWorkspace.shared.open(file)
        } else {
            let folder = settings.notesFolder
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(folder)
        }
    }

    /// ⌃⌥P: pause/resume meeting transcription without ending the session.
    @objc private func togglePauseTranscription() {
        guard appState.isMeetingMode else { return }

        pauseLock.lock()
        meetingTranscriptionPaused.toggle()
        let paused = meetingTranscriptionPaused
        pauseLock.unlock()

        // Drop any half-captured speech so nothing straddles the pause boundary.
        meetingQueue.async { [weak self] in
            self?.meetingSpeechBuffer = Data()
            self?.meetingLastVoiceTime = nil
            self?.meetingSegmentStart = nil
        }
        micMeetingQueue.async { [weak self] in
            self?.micMeetingSpeechBuffer = Data()
            self?.micMeetingLastVoiceTime = nil
            self?.micMeetingSegmentStart = nil
        }

        meetingNotes.appendMarker(paused ? "Transcription paused" : "Transcription resumed")
        pauseMenuItem?.title = paused ? "Resume Transcription" : "Pause Transcription"
        appState.meetingCaption = paused ? "Paused" : "Listening to meeting…"
        appState.isSpeakerActive = false
        statusItem?.button?.image = NSImage(
            systemSymbolName: paused ? "pause.circle.fill" : "headphones.circle.fill",
            accessibilityDescription: "Meeting Mode")
        print(paused ? "⏸ Transcription paused" : "▶️ Transcription resumed")
    }

    // MARK: - PTT Recording Flow

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

    /// Esc pressed while recording: discard the buffer, type nothing.
    private func cancelRecording() {
        guard appState.recordingState == .listening else { return }
        audioCapture.stop()
        audioBuffer = Data()
        appState.recordingState = .idle
        if !appState.isMeetingMode { overlayPanel?.orderOut(nil) }
        print("🎤 Dictation cancelled (Esc)")
    }

    private func stopRecordingAndProcess() {
        audioCapture.stop()

        guard !audioBuffer.isEmpty else {
            appState.recordingState = .idle
            if !appState.isMeetingMode { overlayPanel?.orderOut(nil) }
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
                        if !appState.isMeetingMode { overlayPanel?.orderOut(nil) }
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
                    if !appState.isMeetingMode { overlayPanel?.orderOut(nil) }
                }
            } catch {
                print("❌ Pipeline error: \(error)")
                await MainActor.run { appState.recordingState = .error(error.localizedDescription) }
                try? await Task.sleep(for: .seconds(2))
                await MainActor.run {
                    appState.recordingState = .idle
                    if !appState.isMeetingMode { overlayPanel?.orderOut(nil) }
                }
            }
        }
    }

    // MARK: - Meeting Mode

    @objc private func toggleMeetingMode() {
        if appState.isMeetingMode {
            stopMeetingMode()
        } else {
            Task { @MainActor in await startMeetingMode() }
        }
    }

    @MainActor
    private func startMeetingMode() async {
        // Ensure screen recording permission (SCShareableContent will prompt if needed)
        do {
            try await systemAudioCapture.start()
        } catch {
            print("❌ Could not start system audio capture: \(error.localizedDescription)")
            showError("Screen Recording permission is required for Meeting Mode. Enable it in System Settings → Privacy & Security → Screen Recording.")
            return
        }

        appState.isMeetingMode = true
        appState.meetingCaption = "Listening to meeting…"
        appState.isSpeakerActive = false
        setTranscriptionPaused(false)
        pauseMenuItem?.title = "Pause Transcription"
        meetingModeMenuItem?.state = .on
        meetingStartTime = Date()
        meetingNotes.beginSession()

        // Update status bar icon
        statusItem?.button?.image = NSImage(systemSymbolName: "headphones.circle.fill", accessibilityDescription: "Meeting Mode")

        // Overlay behavior per settings: captions / minimal pill / hidden
        if let panel = overlayPanel {
            switch settings.overlayMode {
            case .captions, .minimal:
                // Wider panel so the caption line has room (minimal just leaves it blank)
                panel.setContentSize(NSSize(width: 380, height: 120))
                positionOverlayPanel(panel)
                panel.ignoresMouseEvents = false  // allow dragging the pill
                panel.orderFront(nil)
            case .hidden:
                panel.orderOut(nil)
            }
        }
        print("📡 Meeting Mode ON")

        setupMeetingAudioCallback()
        setupMicMeetingCallback()
    }

    private func stopMeetingMode() {
        micCapture.stop()
        micMeetingQueue.sync {
            micMeetingSpeechBuffer = Data()
            micMeetingLastVoiceTime = nil
            micMeetingSegmentStart = nil
        }
        systemAudioCapture.stop()

        echoGateLock.lock()
        speakerLastActiveTime = nil
        echoGateLock.unlock()

        setTranscriptionPaused(false)
        DispatchQueue.main.async { [weak self] in
            self?.pauseMenuItem?.title = "Pause Transcription"
        }

        if let start = meetingStartTime {
            meetingNotes.endSession(startedAt: start)
            meetingStartTime = nil
        }

        // Flush any remaining buffer
        meetingQueue.sync {
            meetingSpeechBuffer = Data()
            meetingLastVoiceTime = nil
            meetingSegmentStart = nil
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.appState.isMeetingMode = false
            self.appState.meetingCaption = ""
            self.appState.isSpeakerActive = false
            self.meetingModeMenuItem?.state = .off
            self.statusItem?.button?.image = NSImage(systemSymbolName: "waveform.circle.fill", accessibilityDescription: "GhostWriter")

            if let panel = self.overlayPanel {
                panel.ignoresMouseEvents = true  // restore pass-through
                panel.setContentSize(NSSize(width: 180, height: 180))  // back to PTT size
                self.positionOverlayPanel(panel)
                if self.appState.recordingState == .idle {
                    panel.orderOut(nil)
                }
            }
            print("📡 Meeting Mode OFF")
        }
    }

    private func setupMeetingAudioCallback() {
        let vad = VoiceActivityDetector()
        vad.silenceDebounce = 0.1  // We handle our own longer debounce below

        systemAudioCapture.onAudioBuffer = { [weak self] buffer in
            guard let self, !self.isTranscriptionPaused else { return }
            let rms = vad.calculateRMS(from: buffer)
            let dbfs = vad.rmsToDBFS(rms)
            let isVoice = dbfs >= self.settings.systemAudioThreshold
            self.meetingQueue.async { [weak self] in
                self?.processMeetingBuffer(buffer, isVoice: isVoice, rms: rms)
            }
        }
    }

    // MARK: - Mic Capture (self) in Meeting Mode

    private func setupMicMeetingCallback() {
        let vad = VoiceActivityDetector()
        micCapture.onAudioBuffer = { [weak self] buffer in
            guard let self, !self.isTranscriptionPaused else { return }
            let rms = vad.calculateRMS(from: buffer)
            let isVoice = vad.rmsToDBFS(rms) >= self.settings.meetingMicThreshold  // mic threshold — louder than system audio
            self.micMeetingQueue.async { [weak self] in
                self?.processMicMeetingBuffer(buffer, isVoice: isVoice)
            }
        }
        micCapture.start()
    }

    private func processMicMeetingBuffer(_ buffer: Data, isVoice: Bool) {
        let now = Date()

        // Echo suppression: if the speaker was active within the gate window, the
        // mic is almost certainly hearing the remote party through the speaker, not
        // the local user. Drop it so it isn't mislabeled as "You".
        var speakerActive = false
        if settings.echoSuppressionEnabled {
            echoGateLock.lock()
            if let last = speakerLastActiveTime, now.timeIntervalSince(last) < echoGateWindow {
                speakerActive = true
            }
            echoGateLock.unlock()
        }

        let isVoice = isVoice && !speakerActive

        if isVoice {
            if micMeetingSpeechBuffer.isEmpty { micMeetingSegmentStart = now }
            micMeetingSpeechBuffer.append(buffer)
            micMeetingLastVoiceTime = now
            if let start = micMeetingSegmentStart,
               now.timeIntervalSince(start) >= meetingMaxSegmentSeconds {
                flushMicMeetingSegment()
            }
        } else if let lastVoice = micMeetingLastVoiceTime,
                  now.timeIntervalSince(lastVoice) >= meetingSilenceDebounce,
                  !micMeetingSpeechBuffer.isEmpty {
            flushMicMeetingSegment()
        }
    }

    private func flushMicMeetingSegment() {
        let captured = micMeetingSpeechBuffer
        micMeetingSpeechBuffer = Data()
        micMeetingLastVoiceTime = nil
        micMeetingSegmentStart = nil

        let minBytes = 16000 * 2 / 2
        guard captured.count >= minBytes else { return }

        Task {
            do {
                let text = try await groqService.transcribe(audioData: captured)
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty,
                      !self.whisperHallucinations.contains(trimmed.lowercased()) else { return }
                print("🎤 You: \(trimmed)")
                self.meetingNotes.append(segment: trimmed, speaker: "You")
            } catch {
                print("❌ Mic transcription error: \(error.localizedDescription)")
            }
        }
    }

    private func processMeetingBuffer(_ buffer: Data, isVoice: Bool, rms: Float) {
        // Must be called on meetingQueue
        let now = Date()

        if isVoice {
            // Mark the speaker as active so the mic path can suppress echo.
            echoGateLock.lock()
            speakerLastActiveTime = now
            echoGateLock.unlock()

            if meetingSpeechBuffer.isEmpty {
                meetingSegmentStart = now
                DispatchQueue.main.async { [weak self] in
                    self?.appState.isSpeakerActive = true
                    self?.appState.audioLevel = rms
                }
            }
            meetingSpeechBuffer.append(buffer)
            meetingLastVoiceTime = now

            // Flush if segment is too long (Whisper's 25s limit)
            if let start = meetingSegmentStart,
               now.timeIntervalSince(start) >= meetingMaxSegmentSeconds {
                flushMeetingSegment()
            }
        } else {
            // Update UI level
            DispatchQueue.main.async { [weak self] in
                self?.appState.audioLevel = rms
            }

            // Check if we've been silent long enough after speech
            if let lastVoice = meetingLastVoiceTime,
               now.timeIntervalSince(lastVoice) >= meetingSilenceDebounce,
               !meetingSpeechBuffer.isEmpty {
                flushMeetingSegment()
                DispatchQueue.main.async { [weak self] in
                    self?.appState.isSpeakerActive = false
                }
            }
        }
    }

    // Whisper hallucinates these phrases on short/quiet audio — discard them
    private let whisperHallucinations: Set<String> = [
        "thank you.", "thanks for watching.", "thanks for watching", "thank you",
        "you", ".", " ", "of the", "the", "a", "i", "bye.", "bye",
        "[music]", "[applause]", "[silence]", "♪", "..."
    ]

    private func flushMeetingSegment() {
        // Must be called on meetingQueue
        let capturedAudio = meetingSpeechBuffer
        meetingSpeechBuffer = Data()
        meetingLastVoiceTime = nil
        meetingSegmentStart = nil

        guard !capturedAudio.isEmpty else { return }

        // Require at least 0.5s of audio (16kHz × 2 bytes × 0.5s = 16000 bytes)
        // Whisper hallucinates on very short clips
        let minBytes = 16000 * 2 / 2  // 0.5s at 16kHz Int16
        guard capturedAudio.count >= minBytes else {
            print("⏭ Segment too short (\(capturedAudio.count) bytes), skipping")
            return
        }

        Task {
            do {
                let text = try await groqService.transcribe(audioData: capturedAudio)
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }

                // Discard known Whisper hallucinations
                guard !self.whisperHallucinations.contains(trimmed.lowercased()) else {
                    print("⏭ Filtered hallucination: '\(trimmed)'")
                    return
                }

                print("📡 Meeting transcript: \(trimmed)")
                self.meetingNotes.append(segment: trimmed)
                if self.settings.overlayMode == .captions {
                    await MainActor.run { [weak self] in
                        self?.appState.meetingCaption = trimmed
                    }
                }
            } catch {
                print("❌ Meeting transcription error: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Permissions

    @MainActor
    private func checkPermissions() async {
        // Each permission has its own native macOS prompt; we fire them in order so
        // the user sees exactly one dialog per permission (no duplicate app-driven UI).

        // 1. Microphone — native prompt via AVCaptureDevice.requestAccess.
        _ = await permissionGuard.requestMicrophonePermission()

        // 2. System Audio Recording — no request API, but creating a process tap
        //    surfaces the NSAudioCaptureUsageDescription prompt on first use.
        await systemAudioCapture.requestPermission()

        // 3. Accessibility — native prompt like the mic: checkAccessibilityPermission()
        //    surfaces the system dialog and registers GhostWriter in the list. Only
        //    start the CGEventTap once trusted (starting it untrusted would raise a
        //    second, duplicate prompt).
        if permissionGuard.checkAccessibilityPermission() {
            hotkeyManager.start()
        } else {
            // Not yet trusted: watch for the user toggling it on and start the
            // hotkey the moment access is granted — no relaunch required.
            waitForAccessibilityThenStartHotkey()
        }
    }

    private func waitForAccessibilityThenStartHotkey() {
        Task { @MainActor in
            // Poll for up to 5 minutes while the user grants access in Settings.
            for _ in 0..<300 {
                if permissionGuard.hasAccessibilityPermission {
                    hotkeyManager.start()
                    return
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    @objc private func openPermissions() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    /// Grey out "Pause Transcription" when no meeting is running.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem === pauseMenuItem { return appState.isMeetingMode }
        return true
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "GhostWriter"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - App State

/// Observable state shared across the app — drives the GlowOverlay UI.
@Observable
final class AppState {
    var recordingState: RecordingState = .idle
    var audioLevel: Float = 0.0
    // Meeting mode
    var isMeetingMode: Bool = false
    var isSpeakerActive: Bool = false
    var meetingCaption: String = ""
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
