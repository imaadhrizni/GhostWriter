import SwiftUI
import AppKit

// MARK: - App Delegate

/// Manages the app lifecycle, permission checks, hotkey registration, and the floating overlay.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

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
    private let meetingDetector = MeetingDetector()
    private let voiceActivityDetector = VoiceActivityDetector()
    private let groqService = GroqService()
    private let textPolisher = TextPolisher()
    private let appDetector = AppDetector()
    private let textInjector = TextInjector()
    private let offlineTranscriber = OfflineTranscriber()

    // Shared state
    private let appState = AppState()

    // PTT audio buffer
    private var audioBuffer = Data()
    // Streaming dictation: chunks transcribed while the PTT key is still held,
    // in capture order. Joined with the tail on release.
    private var streamTasks: [Task<String?, Never>] = []
    // Quick note (⌃⌥J): toggle-style dictation into today's QuickNotes file.
    private var quickNoteActive = false
    private var quickNoteMenuItem: NSMenuItem?
    private var quickNoteStartTime: Date?
    private var quickNoteTimer: Timer?

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
    private var meetingTimer: Timer?

    // Experimental diarization (accessed on meetingQueue): voice-fingerprint
    // clustering (pitch + timbre) assigns remote segments to Them / Them 2 / …
    private let speakerProfiler = SpeakerProfiler()

    // Retry queue (main thread): meeting segments whose transcription failed —
    // a network blip should not silently drop a piece of the meeting.
    private struct PendingSegment {
        let audio: Data
        let speaker: String
        let capturedAt: Date
        var attempts: Int
    }
    private var retryQueue: [PendingSegment] = []
    private var retryTimer: Timer?
    private var maxRetryAttempts: Int { max(1, settings.retryMaxAttempts) }

    // In-flight transcription counter: meeting shutdown waits for these so the
    // last spoken words land in the notes before the file is finalized.
    private let pendingLock = NSLock()
    private var pendingTranscriptionCount = 0
    private func beginPendingTranscription() {
        pendingLock.lock(); pendingTranscriptionCount += 1; pendingLock.unlock()
    }
    private func endPendingTranscription() {
        pendingLock.lock(); pendingTranscriptionCount -= 1; pendingLock.unlock()
    }
    private var pendingTranscriptions: Int {
        pendingLock.lock(); defer { pendingLock.unlock() }
        return pendingTranscriptionCount
    }

    // Dictation history (main thread): last N transcriptions for re-inject/recall
    private var dictationHistory: [(date: Date, text: String, duration: TimeInterval)] = []
    private var pttStartTime: Date?
    private var dictationTimer: Timer?

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
    private var statsMenuItem: NSMenuItem?

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
        NotificationCenter.default.addObserver(self, selector: #selector(resetPermissions), name: .resetAllPermissions, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(clearDictationHistory), name: .dictationHistoryDisabled, object: nil)

        if KeychainService.groqAPIKey() == nil {
            Log.app.info("🔑 API Key missing — showing setup window")
            showAPIKeyWindow()
        } else {
            finishInitialization()
        }

        meetingDetector.onMeetingDetected = { [weak self] appName in
            self?.offerToStartMeeting(for: appName)
        }
        meetingDetector.onCallEnded = { [weak self] in
            self?.offerToStopMeeting()
        }
        meetingDetector.start()

        Log.app.info("🎤 GhostWriter launched")
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

    private var notesAssistantWindowController: NotesAssistantWindowController?

    @objc private func showNotesAssistant() {
        if notesAssistantWindowController == nil {
            notesAssistantWindowController = NotesAssistantWindowController()
        }
        notesAssistantWindowController?.showAndActivate()
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

        let menu = NSMenu(title: "Main")
        menu.delegate = self  // refreshes the quick-stats line on open

        // ── Header ──────────────────────────────────────────────
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let titleItem = NSMenuItem(title: "GhostWriter v\(version)", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        let statsItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        statsItem.isEnabled = false
        menu.addItem(statsItem)
        self.statsMenuItem = statsItem

        menu.addItem(NSMenuItem.separator())

        // ── Meeting ─────────────────────────────────────────────
        // ⌃⌥M / ⌃⌥P are true global hotkeys (handled by the CGEventTap); the
        // keys shown here are display-only so users can discover them.
        let meetingItem = NSMenuItem(title: "Start Meeting", action: #selector(toggleMeetingMode), keyEquivalent: "m")
        meetingItem.keyEquivalentModifierMask = [.control, .option]
        meetingItem.image = NSImage(systemSymbolName: "person.2.wave.2", accessibilityDescription: nil)
        meetingItem.target = self
        menu.addItem(meetingItem)
        self.meetingModeMenuItem = meetingItem

        let pauseItem = NSMenuItem(title: "Pause Meeting", action: #selector(togglePauseTranscription), keyEquivalent: "p")
        pauseItem.keyEquivalentModifierMask = [.control, .option]
        pauseItem.image = NSImage(systemSymbolName: "pause.circle", accessibilityDescription: nil)
        pauseItem.target = self
        menu.addItem(pauseItem)
        self.pauseMenuItem = pauseItem

        // Quick note sits with the capture actions — all three are "record
        // something now" verbs sharing the same hotkey family.
        let quickNoteItem = NSMenuItem(title: "Quick Note", action: #selector(toggleQuickNote), keyEquivalent: "j")
        quickNoteItem.keyEquivalentModifierMask = [.control, .option]
        quickNoteItem.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: nil)
        quickNoteItem.target = self
        menu.addItem(quickNoteItem)
        self.quickNoteMenuItem = quickNoteItem

        menu.addItem(NSMenuItem.separator())

        // ── Notes & history ─────────────────────────────────────
        // Notes submenu — current notes, quick notes, recent meetings, folder —
        // rebuilt on open via menuNeedsUpdate
        let meetingNotesItem = NSMenuItem(title: "Notes", action: nil, keyEquivalent: "")
        meetingNotesItem.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)
        let meetingNotesMenu = NSMenu(title: "Notes")
        meetingNotesMenu.delegate = self
        meetingNotesItem.submenu = meetingNotesMenu
        menu.addItem(meetingNotesItem)

        let assistantItem = NSMenuItem(title: "Notes Assistant…", action: #selector(showNotesAssistant), keyEquivalent: "")
        assistantItem.image = NSImage(systemSymbolName: "sparkle.magnifyingglass", accessibilityDescription: nil)
        assistantItem.target = self
        menu.addItem(assistantItem)

        let dictationHistoryItem = NSMenuItem(title: "Recent Dictations", action: nil, keyEquivalent: "")
        dictationHistoryItem.image = NSImage(systemSymbolName: "text.quote", accessibilityDescription: nil)
        let dictationHistoryMenu = NSMenu(title: "Recent Dictations")
        dictationHistoryMenu.delegate = self
        dictationHistoryItem.submenu = dictationHistoryMenu
        menu.addItem(dictationHistoryItem)

        menu.addItem(NSMenuItem.separator())

        // ── Configuration ───────────────────────────────────────
        // No key equivalents on window-opening items: this is a background app
        // (LSUIElement), so menu shortcuts only fire while the menu is open —
        // showing ⌘, / ⌘K would just mislead.
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettingsWindow), keyEquivalent: "")
        settingsItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        settingsItem.target = self
        menu.addItem(settingsItem)

        // Permissions and the API key live in Settings (Permissions pane /
        // General pane) — no need to duplicate them at the top level.
        menu.addItem(NSMenuItem.separator())

        // ── Quit ────────────────────────────────────────────────
        let quitItem = NSMenuItem(title: "Quit GhostWriter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem?.menu = menu
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

        // ⌃⌥V — type the most recent dictation again at the current cursor
        hotkeyManager.onReinjectHotkey = { [weak self] in
            guard let self, let last = self.dictationHistory.first else { return }
            self.textInjector.inject(text: last.text)
        }

        // ⌃⌥J — toggle a quick dictated note into today's notes file
        hotkeyManager.onQuickNoteHotkey = { [weak self] in
            self?.toggleQuickNote()
        }

        // Esc — cancel an in-flight dictation without typing anything
        hotkeyManager.shouldCaptureEscape = { [weak self] in
            self?.appState.recordingState == .listening
        }
        hotkeyManager.onCancelDictation = { [weak self] in
            guard let self else { return }
            if self.quickNoteActive {
                self.cancelQuickNote()
            } else {
                self.cancelRecording()
            }
        }
    }

    // MARK: - Quick Notes (⌃⌥J)

    /// First press starts recording, second press transcribes + saves the note.
    @objc private func toggleQuickNote() {
        if quickNoteActive {
            finishQuickNote()
            return
        }
        // Don't fight the PTT flow over the one AudioCapture engine.
        guard appState.recordingState == .idle else { return }
        guard permissionGuard.hasMicrophonePermission else {
            Log.dictation.warning("⚠️ Missing mic permission — cannot record quick note")
            if !hasPromptedForPermissions {
                Task { @MainActor in await checkPermissions() }
            }
            return
        }

        quickNoteActive = true
        audioBuffer = Data()
        meetingDetector.suppressed = true
        appState.recordingState = .listening
        overlayPanel?.orderFront(nil)
        quickNoteMenuItem?.title = "Finish Quick Note"

        // Live elapsed indicator in the menu bar — skipped during a meeting,
        // where the meeting timer owns the title (the overlay glow already
        // shows the note is recording).
        quickNoteStartTime = Date()
        if !appState.isMeetingMode {
            statusItem?.button?.title = " 📝 0:00"
            quickNoteTimer = Timer.scheduledTimer(
                timeInterval: 1, target: self, selector: #selector(updateQuickNoteTimer),
                userInfo: nil, repeats: true)
        }

        audioCapture.onAudioBuffer = { [weak self] buffer in
            guard let self else { return }
            let rms = self.voiceActivityDetector.calculateRMS(from: buffer)
            Task { @MainActor in self.appState.audioLevel = rms }
            self.audioBuffer.append(buffer)
        }
        audioCapture.start()
        Log.dictation.info("📝 Quick note recording")
    }

    @objc private func updateQuickNoteTimer() {
        guard let start = quickNoteStartTime else { return }
        let elapsed = Int(Date().timeIntervalSince(start))
        statusItem?.button?.title = String(format: " 📝 %d:%02d", elapsed / 60, elapsed % 60)
    }

    /// Synchronous teardown of the recording phase: flag, timer, menu title.
    /// Runs the moment capture stops — NOT deferred to the async save — so the
    /// toggle can't re-enter finish, and a new note can't be torn down by a
    /// stale deferred cleanup.
    private func endQuickNoteRecording() {
        quickNoteActive = false
        quickNoteTimer?.invalidate()
        quickNoteTimer = nil
        quickNoteStartTime = nil
        meetingDetector.suppressed = appState.isMeetingMode
        statusItem?.button?.title = ""  // meeting timer (if any) repaints within 1s
        quickNoteMenuItem?.title = "Quick Note"
    }

    private func hideOverlayUnlessMeeting() {
        if !appState.isMeetingMode { overlayPanel?.orderOut(nil) }
    }

    private func cancelQuickNote() {
        audioCapture.stop()
        audioBuffer = Data()
        endQuickNoteRecording()
        appState.recordingState = .idle
        hideOverlayUnlessMeeting()
        Log.dictation.debug("📝 Quick note cancelled")
    }

    private func finishQuickNote() {
        audioCapture.stop()
        let captured = audioBuffer
        audioBuffer = Data()
        endQuickNoteRecording()

        guard !captured.isEmpty else {
            appState.recordingState = .idle
            hideOverlayUnlessMeeting()
            return
        }
        appState.recordingState = .processing

        Task {
            do {
                let rawText = try await transcribeWithFallback(captured)
                let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    await MainActor.run {
                        appState.recordingState = .idle
                        hideOverlayUnlessMeeting()
                    }
                    return
                }
                // Polish in a notes voice regardless of the frontmost app.
                let context = AppContext(appName: "Quick Notes", bundleID: "quicknote", category: .notes)
                let polished = (try? await textPolisher.polish(rawText: trimmed, appContext: context)) ?? trimmed

                guard let fileURL = MeetingNotesWriter.appendQuickNote(polished) else {
                    // The note must not vanish: park it on the clipboard and say so.
                    await MainActor.run {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(polished, forType: .string)
                        appState.recordingState = .error("Couldn't save quick note — copied to clipboard. Check the Quick Notes folder in Settings.")
                    }
                    try? await Task.sleep(for: .seconds(3))
                    await MainActor.run {
                        appState.recordingState = .idle
                        hideOverlayUnlessMeeting()
                    }
                    return
                }
                if self.settings.quickNoteNotify {
                    NotificationManager.shared.notifyQuickNoteSaved(preview: polished, fileURL: fileURL)
                }
                await MainActor.run { appState.recordingState = .done }
                try? await Task.sleep(for: .milliseconds(500))
                await MainActor.run {
                    appState.recordingState = .idle
                    hideOverlayUnlessMeeting()
                }
            } catch {
                Log.dictation.error("❌ Quick note failed: \(error.localizedDescription)")
                await MainActor.run { appState.recordingState = .error(error.localizedDescription) }
                try? await Task.sleep(for: .seconds(2))
                await MainActor.run {
                    appState.recordingState = .idle
                    hideOverlayUnlessMeeting()
                }
            }
        }
    }

    /// Characters of actual spoken dialogue in a notes file — transcript lines
    /// start with "**[HH:mm:ss]**"; headers, markers, and footers don't count.
    private static func dialogueLength(of transcript: String) -> Int {
        transcript.split(whereSeparator: \.isNewline)
            .filter { $0.hasPrefix("**[") }
            .reduce(0) { $0 + $1.count }
    }

    /// Cleans a model-produced summary: drops the refusal sentinel, empty
    /// sections, and duplicated headings. Returns nil when nothing real remains.
    private static func sanitizedSummary(_ raw: String) -> String? {
        let trimmedRaw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRaw.isEmpty, !trimmedRaw.contains("NOT_ENOUGH_CONTENT") else { return nil }

        // Split into (heading, body) sections
        var sections: [(heading: String?, body: [String])] = [(nil, [])]
        for line in trimmedRaw.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("#") {
                sections.append((String(line), []))
            } else {
                sections[sections.count - 1].body.append(String(line))
            }
        }

        var seenHeadings = Set<String>()
        var output: [String] = []
        var hasContent = false
        for section in sections {
            let body = section.body.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let heading = section.heading {
                let key = heading.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).lowercased()
                guard !seenHeadings.contains(key), !body.isEmpty else { continue }
                seenHeadings.insert(key)
                output.append(heading)
                output.append(body)
                hasContent = true
            } else if !body.isEmpty {
                output.append(body)
                hasContent = true
            }
        }
        return hasContent ? output.joined(separator: "\n\n") : nil
    }

    /// Groq first; when the network is down and the fallback is enabled,
    /// Apple's on-device recognition keeps transcription working.
    private func transcribeWithFallback(_ audioData: Data) async throws -> String {
        do {
            return try await groqService.transcribe(audioData: audioData)
        } catch let error as URLError {
            guard settings.offlineFallback else { throw error }
            Log.api.warning("⚠️ Groq unreachable (\(error.code.rawValue)) — falling back to on-device recognition")
            return try await offlineTranscriber.transcribe(audioData: audioData)
        }
    }

    /// After a meeting ends: append the AI summary (if enabled), then notify (if enabled).
    private func finalizeMeetingNotes(startedAt start: Date) {
        guard let fileURL = meetingNotes.lastCompletedFilePath else { return }

        let elapsed = Int(Date().timeIntervalSince(start))
        let duration = String(format: "%d:%02d", elapsed / 60, elapsed % 60)

        Task { [weak self] in
            guard let self else { return }

            let wantsSummary = self.settings.summariesEnabled
            let wantsActions = self.settings.actionItemsEnabled
            if wantsSummary || wantsActions,
               let transcript = self.meetingNotes.transcriptText(of: fileURL),
               Self.dialogueLength(of: transcript) > 200 {  // measure actual speech, not header/markers
                do {
                    let raw = try await self.textPolisher.summarize(
                        transcript: transcript,
                        template: self.settings.selectedTemplate,
                        includeSummary: wantsSummary,
                        includeActionItems: wantsActions)
                    if let summary = Self.sanitizedSummary(raw) {
                        self.meetingNotes.appendSummary(summary, to: fileURL)
                    } else {
                        Log.meeting.info("⏭ Summary skipped — not enough content")
                    }
                } catch {
                    Log.meeting.error("❌ Summary failed: \(error.localizedDescription)")
                }
            }

            if self.settings.notifyOnMeetingEnd {
                NotificationManager.shared.notifyMeetingSaved(duration: duration, fileURL: fileURL)
            }
        }
    }

    // MARK: - Notes & Pause Hotkeys

    /// ⌃⌥N: reveal the live meeting notes file, or the notes folder when idle.
    @objc private func openNotes() {
        if let file = meetingNotes.currentFilePath
            ?? meetingNotes.lastCompletedFilePath
            ?? MeetingNotesWriter.allMeetingFiles(under: settings.notesFolder).first {
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
        pauseMenuItem?.title = paused ? "Resume Meeting" : "Pause Meeting"
        appState.meetingCaption = paused ? "Paused" : "Listening to meeting…"
        appState.isSpeakerActive = false
        statusItem?.button?.image = NSImage(
            systemSymbolName: paused ? "pause.circle.fill" : "headphones.circle.fill",
            accessibilityDescription: "Meeting Mode")
        Log.meeting.info("\(paused ? "⏸ Transcription paused" : "▶️ Transcription resumed")")
    }

    // MARK: - PTT Recording Flow

    private func startRecording() {
        // A quick note owns the mic engine right now — finish/cancel it first.
        guard !quickNoteActive else { return }
        guard permissionGuard.hasMicrophonePermission,
              permissionGuard.hasAccessibilityPermission else {
            Log.dictation.warning("⚠️ Missing permissions — cannot record")
            if !hasPromptedForPermissions {
                Task { @MainActor in await checkPermissions() }
            }
            return
        }

        audioBuffer = Data()
        streamTasks = []
        pttStartTime = Date()
        meetingDetector.suppressed = true
        appState.recordingState = .listening
        overlayPanel?.orderFront(nil)

        // Live elapsed indicator in the menu bar while the key is held
        dictationTimer = Timer.scheduledTimer(
            timeInterval: 1, target: self, selector: #selector(updateDictationTimer),
            userInfo: nil, repeats: true)

        let streaming = settings.streamingDictation
        // Chunk length from settings: long enough for Whisper to have context,
        // short enough that release-to-text feels instant on long dictations.
        let chunkBytes = Int(16000 * 2 * max(3, settings.streamChunkSeconds))
        audioCapture.onAudioBuffer = { [weak self] buffer in
            guard let self else { return }
            let rms = self.voiceActivityDetector.calculateRMS(from: buffer)
            Task { @MainActor in self.appState.audioLevel = rms }
            self.audioBuffer.append(buffer)

            // Streaming: transcribe in chunks while the key is still held,
            // so a long dictation types almost immediately on release.
            if streaming, self.audioBuffer.count >= chunkBytes {
                let chunk = self.audioBuffer
                self.audioBuffer = Data()
                self.streamTasks.append(Task { [weak self] in
                    try? await self?.transcribeWithFallback(chunk)
                })
            }
        }

        audioCapture.start()
    }


    @objc private func updateDictationTimer() {
        guard let start = pttStartTime else { return }
        let elapsed = Int(Date().timeIntervalSince(start))
        statusItem?.button?.title = String(format: " 🎤 %d:%02d", elapsed / 60, elapsed % 60)
    }

    /// Stop the dictation timer; the meeting timer (if any) repaints within 1s.
    private func stopDictationTimer() {
        dictationTimer?.invalidate()
        dictationTimer = nil
        statusItem?.button?.title = ""
    }

    /// Esc pressed while recording: discard the buffer, type nothing.
    private func cancelRecording() {
        guard appState.recordingState == .listening else { return }
        audioCapture.stop()
        meetingDetector.suppressed = appState.isMeetingMode
        stopDictationTimer()
        streamTasks.forEach { $0.cancel() }
        streamTasks = []
        audioBuffer = Data()
        pttStartTime = nil
        appState.recordingState = .idle
        if !appState.isMeetingMode { overlayPanel?.orderOut(nil) }
        Log.dictation.debug("🎤 Dictation cancelled (Esc)")
    }

    private func stopRecordingAndProcess() {
        // PTT key-up fires even when key-down was refused (e.g. a quick note
        // owns the engine) — don't hijack the quick note's capture.
        guard !quickNoteActive else { return }
        audioCapture.stop()
        meetingDetector.suppressed = appState.isMeetingMode
        stopDictationTimer()
        let dictationDuration = pttStartTime.map { Date().timeIntervalSince($0) } ?? 0
        pttStartTime = nil

        let chunkTasks = streamTasks
        streamTasks = []

        guard !audioBuffer.isEmpty || !chunkTasks.isEmpty else {
            appState.recordingState = .idle
            if !appState.isMeetingMode { overlayPanel?.orderOut(nil) }
            return
        }

        appState.recordingState = .processing
        let capturedAudio = audioBuffer
        audioBuffer = Data()

        Task {
            do {
                // Streamed chunks were transcribed while the key was held —
                // collect them in order, then transcribe only the tail.
                var parts: [String] = []
                for task in chunkTasks {
                    if let piece = await task.value?
                        .trimmingCharacters(in: .whitespacesAndNewlines), !piece.isEmpty {
                        parts.append(piece)
                    }
                }
                if !capturedAudio.isEmpty {
                    let tail = try await transcribeWithFallback(capturedAudio)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !tail.isEmpty { parts.append(tail) }
                }
                let rawText = parts.joined(separator: " ")
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

                await MainActor.run { [weak self] in
                    guard let self else { return }
                    let words = polishedText.split(whereSeparator: \.isWhitespace).count
                    UsageStats.shared.recordDictation(words: words, seconds: dictationDuration)

                    guard self.settings.dictationHistoryEnabled else { return }
                    self.dictationHistory.insert((Date(), polishedText, dictationDuration), at: 0)
                    while self.dictationHistory.count > max(1, self.settings.dictationHistoryLimit) {
                        self.dictationHistory.removeLast()
                    }
                }

                await MainActor.run { appState.recordingState = .done }
                try? await Task.sleep(for: .milliseconds(500))
                await MainActor.run {
                    appState.recordingState = .idle
                    if !appState.isMeetingMode { overlayPanel?.orderOut(nil) }
                }
            } catch {
                Log.dictation.error("❌ Pipeline error: \(error)")
                await MainActor.run { appState.recordingState = .error(error.localizedDescription) }
                try? await Task.sleep(for: .seconds(2))
                await MainActor.run {
                    appState.recordingState = .idle
                    if !appState.isMeetingMode { overlayPanel?.orderOut(nil) }
                }
            }
        }
    }

    // MARK: - Meeting Detection

    /// A conferencing app started using the mic — offer to transcribe.
    private func offerToStartMeeting(for appName: String) {
        guard !appState.isMeetingMode else { return }

        let browser = appName.hasPrefix("browser call")
        confirmMeetingStart(
            title: browser ? "Browser call detected" : "\(appName) call detected",
            message: browser
                ? "\(appName.replacingOccurrences(of: "browser call ", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "()"))) is using your microphone — likely Google Meet or another web call. Start Meeting Mode to transcribe it?"
                : "Looks like a meeting is starting. Start Meeting Mode to transcribe it?",
            confirmTitle: "Start Meeting Mode",
            declineTitle: "Not Now",
            onDecline: { [weak self] in self?.meetingDetector.snooze() })
    }

    /// One prompt is enough: while a start dialog is up, hotkeys and the
    /// detector keep running (runModal services the main queue) — this flag
    /// stops a second dialog from stacking and double-starting the meeting.
    private var meetingStartPromptActive = false

    /// The single start-meeting dialog: template picker + confirm/decline.
    /// Both the manual (⌃⌥M / menu) and auto-detect paths run through here so
    /// they can't drift apart.
    private func confirmMeetingStart(title: String, message: String,
                                     confirmTitle: String, declineTitle: String,
                                     onDecline: (() -> Void)? = nil) {
        guard !meetingStartPromptActive, !appState.isMeetingMode else { return }
        meetingStartPromptActive = true

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: declineTitle)
        alert.alertStyle = .informational

        // Template picker inline — what kind of meeting shapes the summary.
        let picker = Self.makeTemplatePicker(selectedID: settings.selectedTemplateID)
        alert.accessoryView = picker

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            applyTemplateSelection(from: picker)
            // Hold the prompt flag through the async start so a queued ⌃⌥M
            // can't open a spurious second dialog before isMeetingMode flips.
            Task { @MainActor in
                await startMeetingMode()
                meetingStartPromptActive = false
            }
        } else {
            meetingStartPromptActive = false
            onDecline?()
        }
    }

    /// A framed popup of meeting templates (an accessory view without an
    /// explicit frame renders but doesn't receive clicks in NSAlert).
    private static func makeTemplatePicker(selectedID: String) -> NSPopUpButton {
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 240, height: 26), pullsDown: false)
        let templates = AppSettings.shared.allTemplates
        for template in templates {
            picker.addItem(withTitle: template.displayName)
            picker.lastItem?.representedObject = template.id
        }
        if let index = templates.firstIndex(where: { $0.id == selectedID }) {
            picker.selectItem(at: index)
        }
        return picker
    }

    private func applyTemplateSelection(from picker: NSPopUpButton) {
        guard let id = picker.selectedItem?.representedObject as? String else { return }
        settings.selectedTemplateID = id
    }

    /// The tracked call released the mic while Meeting Mode is still running —
    /// offer to stop instead of transcribing an empty room.
    private func offerToStopMeeting() {
        guard appState.isMeetingMode else { return }

        let alert = NSAlert()
        alert.messageText = "Call ended"
        alert.informativeText = "The call seems to be over, but Meeting Mode is still recording. Stop and finalize the notes?"
        alert.addButton(withTitle: "Stop & Save Notes")
        alert.addButton(withTitle: "Keep Recording")
        alert.alertStyle = .informational

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            stopMeetingMode()
        }
    }

    // MARK: - Meeting Mode

    @objc private func toggleMeetingMode() {
        if appState.isMeetingMode {
            stopMeetingMode()
        } else {
            promptTemplateAndStartMeeting()
        }
    }

    /// Manual start (menu or ⌃⌥M): confirm the meeting template first so the
    /// summary matches the kind of meeting.
    private func promptTemplateAndStartMeeting() {
        confirmMeetingStart(
            title: "Start Meeting Mode",
            message: "What kind of meeting is this? The template shapes what the summary extracts.",
            confirmTitle: "Start",
            declineTitle: "Cancel")
    }

    @MainActor
    private func startMeetingMode() async {
        // Re-entrancy guard: two confirm dialogs (or a dialog + hotkey) must
        // never double-start the capture chain and leak timers.
        guard !appState.isMeetingMode else { return }
        // Transcription needs the Groq key — fail fast with guidance instead of
        // silently producing an empty notes file.
        guard KeychainService.groqAPIKey() != nil else {
            showAPIKeyWindow()
            return
        }

        // Starting the capture chain surfaces the System Audio Recording TCC
        // prompt on first use; a failure here usually means it was denied.
        do {
            try await systemAudioCapture.start()
        } catch {
            Log.meeting.error("❌ Could not start system audio capture: \(error.localizedDescription)")
            showError("System Audio Recording permission is required for Meeting Mode. Enable GhostWriter in System Settings → Privacy & Security → Screen & System Audio Recording.")
            return
        }

        appState.isMeetingMode = true
        appState.meetingCaption = "Listening to meeting…"
        appState.isSpeakerActive = false
        setTranscriptionPaused(false)
        pauseMenuItem?.title = "Pause Meeting"
        meetingModeMenuItem?.title = "End Meeting"
        meetingStartTime = Date()
        meetingDetector.suppressed = true
        meetingNotes.beginSession()

        // Reset the speaker profiles for the new session (safe to touch
        // directly — the capture callbacks haven't started yet)
        speakerProfiler.reset()

        // Menu-bar elapsed timer — doubles as a "still recording" indicator
        startMeetingTimer()

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
        Log.meeting.info("📡 Meeting Mode ON")

        setupMeetingAudioCallback()
        setupMicMeetingCallback()
    }

    private func startMeetingTimer() {
        meetingTimer?.invalidate()
        meetingTimer = Timer.scheduledTimer(
            timeInterval: 1, target: self, selector: #selector(updateMeetingTimer),
            userInfo: nil, repeats: true)
    }

    @objc private func updateMeetingTimer() {
        guard let start = meetingStartTime else { return }
        let elapsed = Int(Date().timeIntervalSince(start))
        statusItem?.button?.title = String(format: " %d:%02d", elapsed / 60, elapsed % 60)
    }

    private func stopMeetingMode() {
        meetingTimer?.invalidate()
        meetingTimer = nil
        statusItem?.button?.title = ""

        micCapture.stop()
        systemAudioCapture.stop()

        // Don't immediately re-prompt "start Meeting Mode?" for the very call
        // the user just chose to stop transcribing.
        meetingDetector.suppressed = false
        meetingDetector.snooze()

        // Flush the tail speech still sitting in the buffers — the last words of
        // a meeting must be transcribed, not discarded. (flush* resets the state.)
        micMeetingQueue.sync { flushMicMeetingSegment() }
        meetingQueue.sync { flushMeetingSegment() }

        echoGateLock.lock()
        speakerLastActiveTime = nil
        echoGateLock.unlock()

        setTranscriptionPaused(false)
        DispatchQueue.main.async { [weak self] in
            self?.pauseMenuItem?.title = "Pause Meeting"
        }

        if let start = meetingStartTime {
            meetingStartTime = nil
            UsageStats.shared.recordMeeting(seconds: Date().timeIntervalSince(start))

            // Finalize asynchronously: wait for in-flight transcriptions (incl.
            // the tail we just flushed) so they land in the file, give queued
            // failures one last retry, then write the footer + summary.
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.waitForPendingTranscriptions(timeout: 20)
                await self.finalRetryPass()
                self.meetingNotes.endSession(startedAt: start)
                self.finalizeMeetingNotes(startedAt: start)
            }
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.appState.isMeetingMode = false
            self.appState.meetingCaption = ""
            self.appState.isSpeakerActive = false
            self.meetingModeMenuItem?.title = "Start Meeting"
            self.statusItem?.button?.image = NSImage(systemSymbolName: "waveform.circle.fill", accessibilityDescription: "GhostWriter")

            if let panel = self.overlayPanel {
                panel.ignoresMouseEvents = true  // restore pass-through
                panel.setContentSize(NSSize(width: 180, height: 180))  // back to PTT size
                self.positionOverlayPanel(panel)
                if self.appState.recordingState == .idle {
                    panel.orderOut(nil)
                }
            }
            Log.meeting.info("📡 Meeting Mode OFF")
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
        // Stamp lines with when the speech was captured, not when the API
        // returns — keeps interleaved You/Them lines in true order.
        let capturedAt = micMeetingSegmentStart ?? Date()
        micMeetingSpeechBuffer = Data()
        micMeetingLastVoiceTime = nil
        micMeetingSegmentStart = nil

        let minBytes = 16000 * 2 / 2
        guard captured.count >= minBytes else { return }

        beginPendingTranscription()
        Task {
            defer { self.endPendingTranscription() }
            do {
                let text = try await transcribeWithFallback(captured)
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty,
                      !self.whisperHallucinations.contains(trimmed.lowercased()) else { return }
                Log.meeting.debug("🎤 You: \(trimmed)")
                self.meetingNotes.append(segment: trimmed, speaker: "You", at: capturedAt)
            } catch {
                Log.meeting.error("❌ Mic transcription error: \(error.localizedDescription)")
                await MainActor.run { [weak self] in
                    self?.enqueueFailedSegment(audio: captured, speaker: "You", capturedAt: capturedAt)
                }
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

    // MARK: - Failed-Segment Retry Queue

    /// Queue a failed segment for retry (main thread).
    private func enqueueFailedSegment(audio: Data, speaker: String, capturedAt: Date) {
        retryQueue.append(PendingSegment(audio: audio, speaker: speaker, capturedAt: capturedAt, attempts: 1))
        Log.meeting.warning("⚠️ Segment transcription failed — queued for retry (\(self.retryQueue.count) pending)")
        if retryTimer == nil {
            retryTimer = Timer.scheduledTimer(
                timeInterval: max(5, settings.retryIntervalSeconds), target: self,
                selector: #selector(drainRetryQueue), userInfo: nil, repeats: true)
        }
    }

    @objc private func drainRetryQueue() {
        guard !retryQueue.isEmpty else {
            retryTimer?.invalidate(); retryTimer = nil
            return
        }
        let pending = retryQueue
        retryQueue.removeAll()

        Task { @MainActor [weak self] in
            guard let self else { return }
            for var segment in pending {
                do {
                    let text = try await self.transcribeWithFallback(segment.audio)
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty, !self.whisperHallucinations.contains(trimmed.lowercased()) {
                        self.meetingNotes.append(segment: trimmed, speaker: segment.speaker, at: segment.capturedAt)
                        Log.meeting.info("✅ Recovered segment from \(segment.capturedAt)")
                    }
                } catch {
                    segment.attempts += 1
                    if segment.attempts >= self.maxRetryAttempts {
                        self.writeFailureMarker(for: segment)
                    } else {
                        self.retryQueue.append(segment)
                    }
                }
            }
            if self.retryQueue.isEmpty {
                self.retryTimer?.invalidate(); self.retryTimer = nil
            }
        }
    }

    /// A gap should be visible in the notes, not silent.
    private func writeFailureMarker(for segment: PendingSegment) {
        let seconds = segment.audio.count / (16000 * 2)
        meetingNotes.appendMarker("⚠️ Transcription failed for a \(seconds)s segment captured around this time")
        Log.meeting.error("❌ Gave up on segment from \(segment.capturedAt) after \(self.maxRetryAttempts) attempts")
    }

    /// Wait for in-flight segment transcriptions to finish (bounded).
    private func waitForPendingTranscriptions(timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while pendingTranscriptions > 0 && Date() < deadline {
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        if pendingTranscriptions > 0 {
            Log.meeting.warning("⚠️ \(self.pendingTranscriptions) transcription(s) still pending at meeting end — proceeding")
        }
    }

    /// At meeting end: one final retry for queued failures, then whatever is
    /// still failing becomes a visible marker before the file is finalized.
    @MainActor
    private func finalRetryPass() async {
        retryTimer?.invalidate(); retryTimer = nil
        let pending = retryQueue
        retryQueue.removeAll()

        for segment in pending {
            do {
                let text = try await transcribeWithFallback(segment.audio)
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, !whisperHallucinations.contains(trimmed.lowercased()) {
                    meetingNotes.append(segment: trimmed, speaker: segment.speaker, at: segment.capturedAt)
                }
            } catch {
                writeFailureMarker(for: segment)
            }
        }
    }

    /// Experimental voice-based diarization for remote audio: each segment's
    /// voice fingerprint (pitch, timbre) is clustered into speaker profiles,
    /// so distinct voices get distinct labels (Them / Them 2 / …).
    /// Must be called on meetingQueue.
    private func diarizedSpeakerLabel(for audio: Data) -> String {
        guard settings.diarizationEnabled else { return "Them" }
        return speakerProfiler.label(for: audio)
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
        let capturedAt = meetingSegmentStart ?? Date()
        meetingSpeechBuffer = Data()
        meetingLastVoiceTime = nil
        meetingSegmentStart = nil

        guard !capturedAudio.isEmpty else { return }

        // Require at least 0.5s of audio (16kHz × 2 bytes × 0.5s = 16000 bytes)
        // Whisper hallucinates on very short clips
        let minBytes = 16000 * 2 / 2  // 0.5s at 16kHz Int16
        guard capturedAudio.count >= minBytes else {
            Log.meeting.debug("⏭ Segment too short (\(capturedAudio.count) bytes), skipping")
            return
        }

        let speakerLabel = diarizedSpeakerLabel(for: capturedAudio)

        beginPendingTranscription()
        Task {
            defer { self.endPendingTranscription() }
            do {
                let text = try await transcribeWithFallback(capturedAudio)
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }

                // Discard known Whisper hallucinations
                guard !self.whisperHallucinations.contains(trimmed.lowercased()) else {
                    Log.meeting.debug("⏭ Filtered hallucination: '\(trimmed)'")
                    return
                }

                Log.meeting.debug("📡 Meeting transcript: \(trimmed)")
                self.meetingNotes.append(segment: trimmed, speaker: speakerLabel, at: capturedAt)
                if self.settings.overlayMode == .captions {
                    await MainActor.run { [weak self] in
                        self?.appState.meetingCaption = trimmed
                    }
                }
            } catch {
                Log.meeting.error("❌ Meeting transcription error: \(error.localizedDescription)")
                await MainActor.run { [weak self] in
                    self?.enqueueFailedSegment(audio: capturedAudio, speaker: speakerLabel, capturedAt: capturedAt)
                }
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

    /// Grey out "Pause Transcription" when no meeting is running.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem === pauseMenuItem { return appState.isMeetingMode }
        return true
    }

    // MARK: - History Menus

    private static let historyDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, HH:mm"
        return f
    }()

    /// Rebuilds the Meeting History / Recent Dictations submenus on open.
    func menuNeedsUpdate(_ menu: NSMenu) {
        switch menu.title {
        case "Main":
            let stats = UsageStats.shared
            let weekMeetings = stats.meetingsThisWeek(in: settings.notesFolder)
            statsMenuItem?.title = "\(weekMeetings) meeting\(weekMeetings == 1 ? "" : "s") this week · \(stats.dictationCount) dictations"
            // Pause only makes sense mid-meeting — hide it otherwise.
            pauseMenuItem?.isHidden = !appState.isMeetingMode

        case "Notes":
            menu.removeAllItems()

            // Current (or latest) meeting notes — same action as ⌃⌥N —
            // and today's quick notes, the two "get me to my notes" verbs.
            let openItem = NSMenuItem(title: appState.isMeetingMode ? "Open Current Meeting Notes" : "Open Latest Meeting Notes",
                                      action: #selector(openNotes), keyEquivalent: "n")
            openItem.keyEquivalentModifierMask = [.control, .option]
            openItem.target = self
            menu.addItem(openItem)
            let quickNotesItem = NSMenuItem(title: "Open Today's Quick Notes", action: #selector(openTodaysQuickNotes), keyEquivalent: "")
            quickNotesItem.target = self
            menu.addItem(quickNotesItem)
            menu.addItem(NSMenuItem.separator())

            let files = MeetingNotesWriter.allMeetingFiles(under: settings.notesFolder).prefix(10)

            if files.isEmpty {
                let empty = NSMenuItem(title: "No meetings yet", action: nil, keyEquivalent: "")
                empty.isEnabled = false
                menu.addItem(empty)
            }
            // Group by day so the menu mirrors the notes-folder hierarchy.
            var currentDay = ""
            for file in files {
                let stamp = file.deletingPathExtension().lastPathComponent
                    .replacingOccurrences(of: "Meeting_", with: "")   // yyyy-MM-dd_HH-mm-ss
                let day = String(stamp.prefix(10))
                let time = stamp.count > 11
                    ? String(stamp.dropFirst(11)).replacingOccurrences(of: "-", with: ":")
                    : stamp
                if day != currentDay {
                    currentDay = day
                    let header = NSMenuItem(title: day, action: nil, keyEquivalent: "")
                    header.isEnabled = false
                    menu.addItem(header)
                }
                let item = NSMenuItem(title: time, action: #selector(openMeetingFile(_:)), keyEquivalent: "")
                item.indentationLevel = 1
                item.target = self
                item.representedObject = file
                menu.addItem(item)
            }
            menu.addItem(NSMenuItem.separator())
            let renameItem = NSMenuItem(title: "Rename Speakers…", action: #selector(showRenameSpeakers), keyEquivalent: "")
            renameItem.target = self
            menu.addItem(renameItem)
            let folderItem = NSMenuItem(title: "Open Notes Folder…", action: #selector(openNotesFolder), keyEquivalent: "")
            folderItem.target = self
            menu.addItem(folderItem)

        case "Recent Dictations":
            menu.removeAllItems()
            if !settings.dictationHistoryEnabled {
                let disabled = NSMenuItem(title: "History disabled — enable in Settings → Dictation", action: nil, keyEquivalent: "")
                disabled.isEnabled = false
                menu.addItem(disabled)
                return
            }
            if dictationHistory.isEmpty {
                let empty = NSMenuItem(title: "No dictations yet", action: nil, keyEquivalent: "")
                empty.isEnabled = false
                menu.addItem(empty)
            }
            for entry in dictationHistory {
                let preview = entry.text.count > 48 ? String(entry.text.prefix(48)) + "…" : entry.text
                let duration = String(format: "%.0fs", entry.duration.rounded())
                let item = NSMenuItem(title: "\(Self.historyDateFormatter.string(from: entry.date)) · \(duration)  \(preview)",
                                      action: #selector(copyDictation(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = entry.text
                item.toolTip = "\(entry.text)\n\nClick to copy. ⌃⌥V re-types the most recent one."
                menu.addItem(item)
            }
            if !dictationHistory.isEmpty {
                menu.addItem(NSMenuItem.separator())
                let clearItem = NSMenuItem(title: "Clear History", action: #selector(clearDictationHistory), keyEquivalent: "")
                clearItem.target = self
                menu.addItem(clearItem)
            }

        default:
            break
        }
    }

    @objc private func clearDictationHistory() {
        dictationHistory.removeAll()
    }

    @objc private func openMeetingFile(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
    }

    private var renameSpeakersWindowController: RenameSpeakersWindowController?

    /// Rename Them / Them 2 to real names — per meeting. Opens with the live
    /// meeting preselected when one is running; renames touch only the chosen
    /// file, and live-session overrides apply only to the current meeting.
    @objc private func showRenameSpeakers() {
        renameSpeakersWindowController = RenameSpeakersWindowController(
            liveFile: meetingNotes.currentFilePath,
            onRename: { [weak self] old, new, file in
                guard let self, self.meetingNotes.currentFilePath == file else { return }
                self.meetingNotes.setNameOverride(new, replacing: old)
            })
        renameSpeakersWindowController?.showAndActivate()
    }

    /// Opens today's QuickNotes file, or the most recent one, or the folder.
    @objc private func openTodaysQuickNotes() {
        if let url = MeetingNotesWriter.latestQuickNotesFile() {
            NSWorkspace.shared.open(url)
        } else {
            let folder = settings.quickNotesFolder
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(folder)
        }
    }

    @objc private func openNotesFolder() {
        let folder = settings.notesFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    @objc private func copyDictation(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
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
