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
    private var digestTimer: Timer?
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
    private var liveBriefMenuItem: NSMenuItem?
    private var liveBriefEndMenuItem: NSMenuItem?
    private var statsMenuItem: NSMenuItem?
    private var errorMenuItem: NSMenuItem?

    // Support logic
    private var hasPromptedForPermissions = false

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        installEditMenu()
        setupStatusItem()
        setupOverlayPanel()
        setupHotkeyCallbacks()

        NotificationCenter.default.addObserver(self, selector: #selector(onAPIKeySaved), name: NSNotification.Name("APIKeySaved"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(showAPIKeyWindow), name: .showAPIKeyWindow, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(onSettingsChanged), name: .settingsDidReset, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(resetPermissions), name: .resetAllPermissions, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(clearDictationHistory), name: .dictationHistoryDisabled, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(renameSpeakersForFile(_:)), name: .renameSpeakersForFile, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(showDigestWindow), name: .openDigest, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(openNoteFromNotification(_:)), name: .openNoteFile, object: nil)

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
        startDigestScheduler()

        Log.app.info("🎤 GhostWriter launched")
    }

    // MARK: - Digest scheduler

    /// Check hourly (and once shortly after launch) whether a scheduled digest
    /// is due. Cheap — the real work only runs when the window arrives.
    private func startDigestScheduler() {
        digestTimer?.invalidate()
        digestTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkDigestDue() }   // timer fires on the main run loop
        }
        // A short delay so first-launch UI/permission prompts settle first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            MainActor.assumeIsolated { self?.checkDigestDue() }
        }
    }

    /// Generate the digest if enabled, the scheduled hour has passed today, and
    /// it hasn't already run for this period.
    @MainActor
    private func checkDigestDue() {
        guard settings.digestEnabled else { return }
        let cal = Calendar.current
        let now = Date()
        guard cal.component(.hour, from: now) >= settings.digestHour else { return }

        let today = DateDisplay.posixDay.string(from: now)
        guard settings.lastDigestDay != today else { return }

        // Fire only on the period's boundary: weekly on the chosen weekday,
        // monthly on the 1st, yearly on Jan 1 (daily every day).
        let period = DigestService.period(from: settings.digestFrequency)
        switch period {
        case .daily:   break
        case .weekly:  if cal.component(.weekday, from: now) != settings.digestWeekday { return }
        case .monthly: if cal.component(.day, from: now) != 1 { return }
        case .yearly:  if cal.component(.day, from: now) != 1 || cal.component(.month, from: now) != 1 { return }
        }

        settings.lastDigestDay = today
        DigestService.generate(period: period, notify: true)
        Log.app.info("🗞 Generated \(period.rawValue) digest")
    }

    /// Menu action: open the Ask-your-notes chat window.
    @MainActor @objc private func showAskWindow() {
        AskWindowController.present()
    }

    /// Menu action / notification click: open the interactive Digest window.
    @MainActor @objc private func showDigestWindow() {
        DigestWindowController.present()
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


    private var dictationsWindowController: DictationsWindowController?

    /// Open the searchable Dictations browser.
    @objc private func showDictations() {
        if dictationsWindowController == nil {
            dictationsWindowController = DictationsWindowController()
        }
        dictationsWindowController?.bringToFront()
    }

    private var catalogWindowController: CatalogWindowController?

    /// Open the Catalog — organisations, people, projects, tags over the notes.
    @objc private func showCatalog() {
        if catalogWindowController == nil {
            catalogWindowController = CatalogWindowController()
        }
        catalogWindowController?.bringToFront()
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

    /// Install a minimal main menu with a standard Edit menu. As an accessory
    /// app (LSUIElement) GhostWriter has no menu bar of its own, so without this
    /// the ⌘X/⌘C/⌘V/⌘A/⌘Z key equivalents have no menu items to dispatch to the
    /// focused text field — copy/paste appears "broken" in every text field
    /// (API key, agenda, Ask, settings, the notes editor). The menu bar stays
    /// hidden; only the shortcuts get wired into the responder chain.
    private func installEditMenu() {
        let mainMenu = NSMenu()

        // App menu — the first submenu is conventionally the app menu.
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit GhostWriter",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        // Edit menu — nil targets so each item routes to the first responder
        // (the focused field editor), which implements these selectors.
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        // Find — drives the built-in NSTextView find bar in the notes viewer
        // (⌘F opens it, ⌘G / ⇧⌘G step matches). Items dispatch to the first
        // responder via performTextFinderAction: with the standard action tags.
        editMenu.addItem(.separator())
        let findSubmenu = NSMenu(title: "Find")
        let findItem = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
        findItem.submenu = findSubmenu
        func addFind(_ title: String, _ key: String, _ mods: NSEvent.ModifierFlags,
                     _ action: NSTextFinder.Action) {
            let item = NSMenuItem(title: title, action: #selector(NSTextView.performTextFinderAction(_:)), keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            item.tag = action.rawValue
            findSubmenu.addItem(item)
        }
        addFind("Find…", "f", .command, .showFindInterface)
        addFind("Find Next", "g", .command, .nextMatch)
        addFind("Find Previous", "g", [.command, .shift], .previousMatch)
        addFind("Use Selection for Find", "e", .command, .setSearchString)
        editMenu.addItem(findItem)
        editItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }

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

        // Error banner — hidden unless something recently failed.
        let errorItem = NSMenuItem(title: "", action: #selector(dismissLastError), keyEquivalent: "")
        errorItem.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
        errorItem.target = self
        errorItem.isHidden = true
        menu.addItem(errorItem)
        self.errorMenuItem = errorItem

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

        // Quick Note sits with the capture actions — Start Meeting, Pause, and
        // Quick Note are all "record something now" verbs sharing the ⌃⌥ hotkey
        // family, so they stay contiguous.
        let quickNoteItem = NSMenuItem(title: "Quick Note", action: #selector(toggleQuickNote), keyEquivalent: "j")
        quickNoteItem.keyEquivalentModifierMask = [.control, .option]
        quickNoteItem.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: nil)
        quickNoteItem.target = self
        menu.addItem(quickNoteItem)
        self.quickNoteMenuItem = quickNoteItem

        // Live Brief is a display toggle (show/hide the floating panel), not a
        // capture verb, so it follows the capture cluster. Hidden unless a
        // meeting's live assistant is active (see menuNeedsUpdate).
        let liveBriefItem = NSMenuItem(title: "Hide Live Brief", action: #selector(toggleLiveBrief), keyEquivalent: "")
        liveBriefItem.image = NSImage(systemSymbolName: "sparkles.rectangle.stack", accessibilityDescription: nil)
        liveBriefItem.target = self
        menu.addItem(liveBriefItem)
        self.liveBriefMenuItem = liveBriefItem

        // Fully turn the brief off for this meeting (stops AI updates); shown
        // only while it's still running, since "Show/Resume" covers the rest.
        let liveBriefEndItem = NSMenuItem(title: "Turn Off Live Brief", action: #selector(endLiveBrief), keyEquivalent: "")
        liveBriefEndItem.image = NSImage(systemSymbolName: "stop.circle", accessibilityDescription: nil)
        liveBriefEndItem.target = self
        menu.addItem(liveBriefEndItem)
        self.liveBriefEndMenuItem = liveBriefEndItem

        menu.addItem(NSMenuItem.separator())

        // ── Notes & history ─────────────────────────────────────
        // Notes submenu — current notes, quick notes, recent meetings, folder —
        // rebuilt on open via menuNeedsUpdate
        let meetingNotesItem = NSMenuItem(title: "Notes & History", action: nil, keyEquivalent: "")
        meetingNotesItem.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)
        let meetingNotesMenu = NSMenu(title: "Notes & History")
        meetingNotesMenu.delegate = self
        meetingNotesItem.submenu = meetingNotesMenu
        menu.addItem(meetingNotesItem)

        // Catalog is the primary organiser — it sits directly under Notes,
        // above the raw dictation archive.
        let catalogItem = NSMenuItem(title: "Catalog…", action: #selector(showCatalog), keyEquivalent: "")
        catalogItem.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil)
        catalogItem.target = self
        menu.addItem(catalogItem)

        let dictationsItem = NSMenuItem(title: "Dictations…", action: #selector(showDictations), keyEquivalent: "")
        dictationsItem.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)
        dictationsItem.target = self
        menu.addItem(dictationsItem)

        // AI-over-notes actions, set apart from the raw browse/archive items above.
        menu.addItem(NSMenuItem.separator())

        let digestItem = NSMenuItem(title: "Today's Digest…", action: #selector(showDigestWindow), keyEquivalent: "")
        digestItem.image = NSImage(systemSymbolName: "newspaper", accessibilityDescription: nil)
        digestItem.target = self
        menu.addItem(digestItem)

        let askItem = NSMenuItem(title: "Ask Your Notes…", action: #selector(showAskWindow), keyEquivalent: "")
        askItem.image = NSImage(systemSymbolName: "sparkle.magnifyingglass", accessibilityDescription: nil)
        askItem.target = self
        menu.addItem(askItem)

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
        alert.informativeText = "This revokes GhostWriter's Microphone, Accessibility, System Audio Recording, and browser Automation permissions, then relaunches the app so macOS can prompt you again."
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

        // ⌃⌥B — drop a timestamped bookmark in the running meeting
        hotkeyManager.onBookmarkHotkey = { [weak self] in
            self?.dropMeetingBookmark()
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
                reportError("Quick note failed: \(error.localizedDescription)")
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
        // Only bail when the model says the WHOLE meeting was too thin — a
        // stray token inside one section must not discard the entire summary.
        guard !trimmedRaw.isEmpty, trimmedRaw != "NOT_ENOUGH_CONTENT" else { return nil }

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
        var sawHeading = false
        for section in sections {
            let body = section.body.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let heading = section.heading {
                // Keep every distinct heading — even with an empty body, so the
                // structure (Summary / Decisions / Action Items …) is always
                // visible. Blank sections render an explicit "_None_".
                let key = heading.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).lowercased()
                guard !seenHeadings.contains(key) else { continue }
                seenHeadings.insert(key)
                output.append(heading)
                output.append(body.isEmpty ? "_None_" : body)
                sawHeading = true
            } else if !body.isEmpty {
                output.append(body)
            }
        }
        return sawHeading ? output.joined(separator: "\n\n") : nil
    }

    /// The single transcription choke point for dictation, quick notes, and
    /// meetings. Local-only mode goes straight to on-device recognition; other-
    /// wise Groq first, falling back on-device when the network is down. The
    /// result is passed through optional redaction before anyone sees it.
    private func transcribeWithFallback(_ audioData: Data, context: String = "") async throws -> String {
        let text: String
        if settings.localOnlyMode {
            text = try await offlineTranscriber.transcribe(audioData: audioData, context: context)
        } else {
            do {
                text = try await groqService.transcribe(audioData: audioData, context: context)
            } catch {
                // Fall back on ANY Groq failure — network down, 5xx, rate
                // limit, bad response — not just connectivity errors.
                guard settings.offlineFallback else { throw error }
                Log.api.warning("⚠️ Groq transcription failed (\(error.localizedDescription)) — falling back to on-device recognition")
                text = try await offlineTranscriber.transcribe(audioData: audioData, context: context)
            }
        }
        return Redactor.redact(text)
    }

    /// ⌃⌥B handler — bookmark the current moment in a running meeting. Writes an
    /// inline marker now; a jump-list is appended when the meeting ends.
    private func dropMeetingBookmark() {
        guard appState.isMeetingMode, let start = meetingStartTime else { return }
        let elapsed = Int(Date().timeIntervalSince(start))
        meetingNotes.addBookmark(elapsed: elapsed)
        // Light confirmation — shows in caption mode, harmlessly overwritten by
        // the next transcript line otherwise.
        appState.meetingCaption = String(format: "★ Bookmarked %d:%02d", elapsed / 60, elapsed % 60)
    }

    /// After a meeting ends: append the AI summary (if enabled), then notify (if enabled).
    private func finalizeMeetingNotes(startedAt start: Date, agenda: [String] = [],
                                      catalogTarget: (kind: String, id: String)? = nil) {
        guard let fileURL = meetingNotes.lastCompletedFilePath else { return }

        let elapsed = Int(Date().timeIntervalSince(start))
        let duration = String(format: "%d:%02d", elapsed / 60, elapsed % 60)

        Task { [weak self] in
            guard let self else { return }

            // Link the note into the Catalog under the opportunity/org chosen at
            // start (if any), creating its catalog row from the file path.
            await MainActor.run {
                guard let target = catalogTarget else { return }
                let store = CatalogStore.shared
                let root = AppSettings.shared.notesFolder.path + "/"
                let rel = fileURL.path.replacingOccurrences(of: root, with: "")
                let note = store.note(forRelativePath: rel,
                                      title: fileURL.deletingPathExtension().lastPathComponent,
                                      date: start)
                if target.kind == "opp" { store.setOpportunity(target.id, on: note.id, true) }
                else if target.kind == "org" { store.setOrg(target.id, on: note.id, true) }

                // Mirror the link into the note's front-matter so the file
                // itself carries who it's about (visible in Obsidian, and it
                // survives independently of the Catalog database).
                if AppSettings.shared.frontMatterEnabled {
                    var fields: [(key: String, value: String)] = []
                    if target.kind == "opp", let opp = store.opportunity(target.id) {
                        fields.append(("opportunity", opp.name))
                        // Org sits above the opportunity via its project.
                        if let pid = opp.projectID, let oid = store.project(pid)?.orgID,
                           let org = store.org(oid) {
                            fields.append(("org", org.name))
                        }
                    } else if target.kind == "org", let org = store.org(target.id) {
                        fields.append(("org", org.name))
                    }
                    if !fields.isEmpty {
                        MeetingNotesWriter.addFrontMatterFields(fields, to: fileURL)
                        MeetingNotesWriter.mirrorFieldsToTags(fields, to: fileURL)
                    }
                }
            }

            // Bookmarks jump-list (timestamps dropped via ⌃⌥B during the meeting).
            self.meetingNotes.appendBookmarks(to: fileURL)

            // Auto-name recurring voices (learned from past renames) before
            // summarizing, so real names flow into the summary and tags too.
            self.applyVoiceIdentities(to: fileURL)

            let wantsSummary = self.settings.summariesEnabled
            let wantsActions = self.settings.actionItemsEnabled
            let wantsStructured = self.settings.structuredExtraction
            let wantsChapters = self.settings.topicChapters
            // Enough real speech to work with? (measure dialogue, not header/markers)
            if let transcript = self.meetingNotes.transcriptText(of: fileURL),
               Self.dialogueLength(of: transcript) > 200 {

            // Keyword/competitor radar: a purely local scan (works offline), so
            // it runs before the cloud/on-device branch. Matches go into a
            // Mentions section and — with front-matter on — into tags for the
            // Catalog to filter by.
            let watchTerms = self.settings.watchlist()
            if !watchTerms.isEmpty {
                let matches = MeetingNotesWriter.mentionCounts(in: transcript, terms: watchTerms)
                if !matches.isEmpty {
                    self.meetingNotes.appendMentions(matches, to: fileURL)
                    if self.settings.frontMatterEnabled {
                        MeetingNotesWriter.addFrontMatterTags(matches.map { $0.term }, to: fileURL)
                    }
                }
            }

            // Local-only mode never contacts the network. It used to skip all AI;
            // now it runs on-device (Apple Intelligence + NaturalLanguage) instead.
            if self.settings.localOnlyMode {
                await self.finalizeOnDevice(transcript: transcript, fileURL: fileURL,
                                            wantsSummary: wantsSummary, wantsActions: wantsActions)
            } else {
                // Cloud path. Each feature below is independently toggleable.
                if wantsSummary || wantsActions || wantsStructured {
                    do {
                        let raw = try await self.textPolisher.summarize(
                            transcript: transcript,
                            template: self.settings.selectedTemplate,
                            includeSummary: wantsSummary,
                            includeActionItems: wantsActions,
                            includeStructured: wantsStructured)
                        if let summary = Self.sanitizedSummary(raw) {
                            self.meetingNotes.appendSummary(summary, to: fileURL)
                        } else {
                            Log.meeting.info("⏭ Summary skipped — not enough content")
                        }
                    } catch {
                        Log.meeting.error("❌ Summary failed: \(error.localizedDescription)")
                        self.reportError("Meeting summary failed: \(error.localizedDescription)")
                    }
                }

                // A concise AI title for the note's front-matter (the on-disk
                // filename stays Meeting_<timestamp> so Catalog links hold).
                if self.settings.frontMatterEnabled {
                    if let title = try? await self.textPolisher.meetingTitle(transcript: transcript) {
                        MeetingNotesWriter.setFrontMatterTitle(title, to: fileURL)
                    }
                }

                // Unanswered questions: raised-but-not-resolved follow-up items.
                if self.settings.extractUnanswered {
                    do {
                        let qs = try await self.textPolisher.unansweredQuestions(transcript: transcript)
                        if !qs.isEmpty { self.meetingNotes.appendUnansweredQuestions(qs, to: fileURL) }
                    } catch {
                        Log.meeting.error("❌ Unanswered-questions extraction failed: \(error.localizedDescription)")
                    }
                }

                // Topic chapters: a timestamped jump-list segmenting the meeting.
                if wantsChapters {
                    do {
                        let chapters = try await self.textPolisher.chapters(transcript: transcript)
                        if !chapters.isEmpty { self.meetingNotes.appendChapters(chapters, to: fileURL) }
                    } catch {
                        Log.meeting.error("❌ Chapters failed: \(error.localizedDescription)")
                    }
                }

                // Agenda section: planned items (covered?) + topics the meeting
                // itself raised (dynamic). Independent of the summary toggle —
                // writes whenever there's an agenda or discovered topics. Fast
                // model — this is a notes footer, not a blocking decision.
                // Prefer the live panel's accumulated agenda (the full 6–8 the
                // user watched build up) over a fresh one-shot, which would only
                // rediscover a couple of topics.
                let liveAgenda = await LiveMeetingAssistant.shared.coverageSnapshot
                if !liveAgenda.isEmpty {
                    self.meetingNotes.appendAgenda(liveAgenda, to: fileURL)
                } else {
                    let status = await self.textPolisher.agendaStatus(
                        userAgenda: agenda, transcript: transcript, preferFast: true)
                    let userEntries = zip(agenda, status.userCovered).map { (text: $0.0, covered: $0.1, dynamic: false) }
                    // Discovered topics are surfaced, never auto-completed.
                    let dynEntries = status.newTopics.map { (text: $0, covered: false, dynamic: true) }
                    self.meetingNotes.appendAgenda(userEntries + dynEntries, to: fileURL)
                }

                // Auto-tag topics + entities into the front-matter (needs front-matter on).
                // Person names are only harvested when redaction is off.
                if self.settings.autoTagging, self.settings.frontMatterEnabled {
                    let includePeople = !self.settings.redactionEnabled
                    var meta = await self.textPolisher.extractMetadata(
                        transcript: transcript, includePeople: includePeople)
                    // Fall back to on-device NER when the cloud call came back empty
                    // (e.g. Groq rate-limited) so tagging still happens.
                    if meta.isEmpty {
                        meta = OnDeviceNLP.extractMetadata(transcript: transcript, includePeople: includePeople)
                    }
                    if !meta.isEmpty {
                        let customer = await self.validatedCustomer(meta.customer)
                        MeetingNotesWriter.addMeetingMetadata(
                            topics: meta.topics, people: meta.people,
                            customer: customer, project: meta.project, to: fileURL)
                    }
                }

                // Per-meeting-type key fields (deal stage, recommendation, …):
                // a readable Key Details section, plus machine-readable
                // front-matter fields; category fields are mirrored into tags
                // so they're filterable in the Catalog.
                if self.settings.extractKeyFields {
                    let schema = self.settings.selectedTemplate.keyFields
                    let extracted = await self.textPolisher.extractKeyFields(
                        transcript: transcript, fields: schema)
                    if !extracted.isEmpty {
                        self.meetingNotes.appendKeyDetails(
                            extracted.map { ($0.field.label, $0.value) }, to: fileURL)
                        if self.settings.frontMatterEnabled {
                            let pairs = extracted.map { ($0.field.key, $0.value) }
                            MeetingNotesWriter.addFrontMatterFields(pairs, to: fileURL)
                            let categories = extracted
                                .filter { $0.field.kind == .category }
                                .map { ($0.field.key, $0.value) }
                            MeetingNotesWriter.mirrorFieldsToTags(categories, to: fileURL)
                        }
                    }
                }
            }   // end cloud path
            }   // end "enough speech"

            if self.settings.notifyOnMeetingEnd {
                NotificationManager.shared.notifyMeetingSaved(duration: duration, fileURL: fileURL)
            }
            self.warnIfOverBudget()

            // Fire user-configured integrations (local script hook / outgoing
            // webhook). Runs last, so the payload reflects the finished note.
            // Metadata only, redaction-aware, and a no-op in Local-only mode.
            await MainActor.run {
                self.dispatchMeetingEvent(fileURL: fileURL, start: start, durationSeconds: elapsed)
            }
        }
    }

    /// Build the "meeting finished" event payload from the saved note and hand
    /// it to `EventDispatcher`. Catalog resolution and front-matter reads happen
    /// here (on the main actor); the dispatcher itself does the redaction,
    /// script launch, and webhook POST off the main thread.
    @MainActor
    private func dispatchMeetingEvent(fileURL: URL, start: Date, durationSeconds: Int) {
        let s = AppSettings.shared
        guard !s.localOnlyMode, (s.scriptHookEnabled || s.webhookEnabled) else { return }

        let markdown = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        let title = FrontMatter.title(in: markdown)
            ?? fileURL.deletingPathExtension().lastPathComponent
        let tags = FrontMatter.tags(in: markdown)
        let typeID = FrontMatter.field("gw_meeting_type", in: markdown)
        let meetingType = typeID.flatMap { id in
            AppSettings.shared.allTemplates.first { $0.id == id }?.displayName
        } ?? typeID

        // Resolve the org / opportunity / project chain from the Catalog link.
        var org: String?, opportunity: String?, project: String?
        let store = CatalogStore.shared
        let root = s.notesFolder.path + "/"
        let rel = fileURL.path.replacingOccurrences(of: root, with: "")
        if let note = store.doc.notes.first(where: { $0.filePath == rel }) {
            if let oppID = note.opportunityIDs.first, let opp = store.opportunity(oppID) {
                opportunity = opp.name
                if let pid = opp.projectID, let proj = store.project(pid) {
                    project = proj.name
                    org = proj.orgID.flatMap { store.org($0)?.name }
                }
            } else if let projID = note.projectIDs.first, let proj = store.project(projID) {
                project = proj.name
                org = proj.orgID.flatMap { store.org($0)?.name }
            } else if let orgID = note.orgIDs.first {
                org = store.org(orgID)?.name
            }
        }

        let payload = EventDispatcher.MeetingFinishedPayload(
            title: title,
            file: fileURL.path,
            date: ISO8601DateFormatter().string(from: start),
            durationSeconds: durationSeconds,
            meetingType: meetingType,
            organisation: org,
            opportunity: opportunity,
            project: project,
            tags: tags)
        EventDispatcher.dispatch(payload)
    }

    /// Local-only finalize: summarize and tag entirely on-device (Apple
    /// Intelligence for the summary when available, NaturalLanguage NER for
    /// front-matter tags — which works on every Mac). Best-effort; anything
    /// unavailable is simply skipped, matching the old "no network" contract.
    private func finalizeOnDevice(transcript: String, fileURL: URL,
                                  wantsSummary: Bool, wantsActions: Bool) async {
        if (wantsSummary || wantsActions), AppleIntelligence.isAvailable {
            let sections = wantsSummary ? settings.selectedTemplate.summarySections : []
            if let raw = await AppleIntelligence.summarizeMeeting(
                transcript: transcript, sections: sections, includeActionItems: wantsActions),
               let summary = Self.sanitizedSummary(raw) {
                meetingNotes.appendSummary(
                    summary + "\n\n_— generated on-device with Apple Intelligence_", to: fileURL)
            } else {
                Log.meeting.info("⏭ On-device summary unavailable or empty")
            }
        }

        // Front-matter tags via on-device NER — available on every Mac.
        if settings.autoTagging, settings.frontMatterEnabled {
            let meta = OnDeviceNLP.extractMetadata(
                transcript: transcript, includePeople: !settings.redactionEnabled)
            if !meta.isEmpty {
                let customer = await validatedCustomer(meta.customer)
                MeetingNotesWriter.addMeetingMetadata(
                    topics: meta.topics, people: meta.people,
                    customer: customer, project: meta.project, to: fileURL)
            }
        }
    }

    /// Guard against low-confidence `customer` guesses from entity extraction.
    /// Accepts a name that matches a known Catalog org/opportunity (or alias);
    /// otherwise drops a lone short token or an all-caps acronym — almost always
    /// transcript noise (e.g. a mis-heard "Wwe") rather than a real customer.
    /// Multi-word names pass through so genuinely new customers aren't lost.
    @MainActor
    private func validatedCustomer(_ raw: String?) -> String? {
        guard let name = raw?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
        let store = CatalogStore.shared
        let known = store.doc.orgs.flatMap { [$0.name] + $0.aliases }
            + store.doc.opportunities.map(\.name)
        if known.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { return name }
        let tokens = name.split(whereSeparator: { $0 == " " })
        if tokens.count == 1 {
            let t = String(tokens[0])
            if t.count <= 3 || t == t.uppercased() { return nil }
        }
        return name
    }

    /// Fire a single monthly notification the first time the estimated spend
    /// crosses the configured budget. Cheap to call after any billable work.
    private func warnIfOverBudget() {
        let stats = UsageStats.shared
        guard stats.shouldWarnBudgetOnce() else { return }
        NotificationManager.shared.notifyBudgetExceeded(
            spent: UsageStats.currency(stats.costThisMonthUSD),
            budget: UsageStats.currency(settings.monthlyBudgetUSD))
    }

    // MARK: - Notes & Pause Hotkeys

    /// ⌃⌥N: reveal the live meeting notes file, or the notes folder when idle.
    /// A meeting-saved (or other) notification was clicked — open that note in
    /// the in-app viewer, honoring the "open externally" setting like every
    /// other note-open path.
    @objc private func openNoteFromNotification(_ note: Notification) {
        guard let url = note.object as? URL else { return }
        // Notification-center callbacks arrive off the main thread; UI must be
        // presented on main, and the accessory app needs activating to front it.
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            NotesViewerWindowController.present(fileURL: url)
        }
    }

    @objc private func openNotes() {
        if let file = meetingNotes.currentFilePath
            ?? meetingNotes.lastCompletedFilePath
            ?? MeetingNotesWriter.allMeetingFiles(under: settings.notesFolder).first {
            // Routes to the in-app viewer, or the OS default app when
            // "open notes externally" is on.
            NotesViewerWindowController.present(fileURL: file)
        } else {
            let folder = settings.notesFolder
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(folder)
        }
    }

    /// ⌃⌥P: pause/resume meeting transcription without ending the session.
    /// Toggle the floating Live Brief panel without stopping the briefing.
    @objc private func toggleLiveBrief() {
        MainActor.assumeIsolated {
            let assistant = LiveMeetingAssistant.shared
            if assistant.isActive {
                if assistant.visible { assistant.hide() } else { assistant.show() }
            } else if assistant.ended {
                assistant.resume()
            } else {
                startLiveBrief()   // never started this meeting — begin now
            }
        }
    }

    @objc private func endLiveBrief() {
        MainActor.assumeIsolated { LiveMeetingAssistant.shared.endForMeeting() }
    }

    /// Begin the live brief in the middle of a meeting that started without it.
    /// Force-enables regardless of the per-meeting/global default; the assistant
    /// still self-guards against local-only mode / missing API key.
    private func startLiveBrief() {
        MainActor.assumeIsolated {
            guard appState.isMeetingMode, !LiveMeetingAssistant.shared.isActive else { return }
            LiveMeetingAssistant.shared.start(
                transcriptProvider: { [weak self] in
                    guard let url = self?.meetingNotes.currentFilePath else { return nil }
                    return self?.meetingNotes.transcriptText(of: url)
                },
                template: settings.selectedTemplate,
                agenda: meetingAgenda,
                enabled: true)
        }
    }

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
                    // Prime the final tail with the chunks already transcribed
                    // in this same dictation, so terms stay consistent.
                    let tail = try await transcribeWithFallback(capturedAudio, context: parts.joined(separator: " "))
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

                var activeApp = appDetector.currentApp()
                // For browsers, read the active tab host (if enabled) so domain
                // rules and the log can distinguish sites like Gmail.
                if activeApp.category == .browser, settings.browserTabDetection {
                    let bundleID = activeApp.bundleID
                    let host = await MainActor.run { BrowserURL.host(forBundleID: bundleID) }
                    activeApp = AppContext(appName: activeApp.appName, bundleID: bundleID,
                                           category: .browser, host: host)
                }
                let style = settings.resolvedDictationStyle(for: activeApp)
                let polishedText = try await textPolisher.polish(rawText: rawText, appContext: activeApp)
                textInjector.inject(text: polishedText)

                let words = polishedText.split(whereSeparator: \.isWhitespace).count

                // Optional archive: one Markdown file per dictation, with metadata.
                if settings.saveDictations {
                    MeetingNotesWriter.saveDictation(
                        text: polishedText, app: activeApp.appName, host: activeApp.host,
                        style: style.displayName, seconds: Int(dictationDuration.rounded()), words: words)
                }

                await MainActor.run { [weak self] in
                    guard let self else { return }
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
                reportError("Dictation failed: \(error.localizedDescription)")
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

    /// Agenda items entered at meeting start (may be empty) — drives the
    /// live coverage checklist and the end-of-meeting "did we cover it?" check.
    private var meetingAgenda: [String] = []

    /// Whether to show the live brief for the current meeting. Set from the
    /// start dialog's checkbox (defaults to the global setting); auto-started
    /// meetings with no dialog fall back to `nil` → the global setting.
    private var meetingLiveBrief: Bool?

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

        // Inline controls: a catalog link (opportunity/org to file the note
        // under), the template (shapes the summary), an optional agenda, and the
        // per-meeting live-brief switch.
        let accessory = Self.makeStartAccessory(selectedID: settings.selectedTemplateID,
                                                catalogOptions: Self.catalogLinkOptions())
        alert.accessoryView = accessory

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            applyTemplateSelection(from: accessory.picker)
            meetingAgenda = Self.parseAgenda(accessory.agendaField.stringValue)
            meetingLiveBrief = accessory.liveBrief.isEnabled ? (accessory.liveBrief.state == .on) : false
            meetingCatalogTarget = resolveCatalogTarget(accessory.catalog.selectedItem?.representedObject as? String)
            // Prep card: surface recent context for the chosen org/opp before
            // recording starts — unless switched off for this meeting.
            if let target = meetingCatalogTarget, accessory.prepCard.state == .on {
                showMeetingPrepCard(for: target)
            }
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

    /// Build the start-dialog catalog picker options: opportunities, orgs, and
    /// two quick-add entries. Runs on the main actor (CatalogStore is isolated).
    private static func catalogLinkOptions() -> [(title: String, repr: String)] {
        MainActor.assumeIsolated {
            let store = CatalogStore.shared
            var opts: [(String, String)] = [("No link", "")]
            let opps = store.doc.opportunities.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            let orgs = store.orgsSorted
            if !opps.isEmpty { opts.append(("__sep__", "__sep__")) }
            for o in opps { opts.append(("◆ \(o.name)", "opp:\(o.id)")) }
            if !orgs.isEmpty { opts.append(("__sep__", "__sep__")) }
            for o in orgs { opts.append(("🏢 \(store.orgPath(of: o.id))", "org:\(o.id)")) }
            opts.append(("__sep__", "__sep__"))
            opts.append(("➕ New Opportunity…", "new:opp"))
            opts.append(("➕ New Organisation…", "new:org"))
            return opts.map { (title: $0.0, repr: $0.1) }
        }
    }

    /// Turn the picker's selection into a catalog target, handling the two
    /// quick-add entries by prompting for a name and creating the entity.
    private func resolveCatalogTarget(_ repr: String?) -> (kind: String, id: String)? {
        guard let repr, !repr.isEmpty else { return nil }
        // A new opportunity gets the full Quick Add (org → project → opp → …).
        if repr == "new:opp" {
            return runQuickAddForOpportunity().map { ("opp", $0) }
        }
        if repr == "new:org" {
            guard let name = promptNewCatalogName("New Organisation") else { return nil }
            return MainActor.assumeIsolated { ("org", CatalogStore.shared.addOrg(name: name).id) }
        }
        let parts = repr.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        return (parts[0], parts[1])
    }

    /// Proper-noun glossary for the meeting in progress — the linked entity
    /// (opportunity / project / org), the people on its recent notes, and the
    /// voice identities taught so far — capped and formatted for the Whisper
    /// prompt. CatalogStore is main-actor isolated, so this is too.
    @MainActor
    private func buildSessionGlossary(for target: (kind: String, id: String)?) -> String {
        let store = CatalogStore.shared
        var terms: [String] = []
        var scope: [CatalogNote] = []

        if let target {
            if target.kind == "opp", let opp = store.opportunity(target.id) {
                terms.append(opp.name)
                if let proj = store.project(opp.projectID) { terms.append(proj.name) }
                if let org = store.org(forOpportunity: opp) { terms.append(org.name) }
                scope = store.notes(forOpportunity: opp)
            } else if target.kind == "org", let org = store.org(target.id) {
                terms.append(org.name)
                scope = store.notes(forOrg: org.id, includingDescendants: true)
            }
        }

        // People who appear on the linked entity's notes.
        let personIDs = Set(scope.flatMap { $0.personIDs })
        terms.append(contentsOf: store.doc.people.filter { personIDs.contains($0.id) }.map(\.name))
        // Voices you've taught by renaming speakers in past meetings.
        terms.append(contentsOf: VoiceIdentityStore.shared.knownNames)

        // Dedupe (case-insensitive), drop empties, cap length for Whisper's
        // short prompt window.
        var seen = Set<String>(), unique: [String] = []
        for t in terms {
            let name = t.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, seen.insert(name.lowercased()).inserted else { continue }
            unique.append(name)
        }
        guard !unique.isEmpty else { return "" }
        return String(("Names: " + unique.joined(separator: ", ")).prefix(400))
    }

    /// Meeting prep card: a quick, non-editable recap of recent context for the
    /// org/opportunity chosen in the Start dialog, shown just before recording.
    /// Reuses the catalog's relationship timeline (recent notes). Skipped when
    /// there's no prior history to show.
    private func showMeetingPrepCard(for target: (kind: String, id: String)) {
        let prep: (name: String, notes: [CatalogNote])? = MainActor.assumeIsolated {
            let store = CatalogStore.shared
            let name: String
            let notes: [CatalogNote]
            if target.kind == "opp", let o = store.opportunity(target.id) {
                name = o.name; notes = store.notes(forOpportunity: o)
            } else if target.kind == "org", let o = store.org(target.id) {
                name = store.orgPath(of: o.id); notes = store.notes(forOrg: o.id, includingDescendants: true)
            } else { return nil }
            let recent = Array(notes.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }.prefix(3))
            return recent.isEmpty ? nil : (name, recent)
        }
        guard let prep else { return }   // nothing to prep from — don't interrupt
        // Non-modal so you can open and read a note while the meeting records.
        MeetingPrepWindowController.present(entityName: prep.name, notes: prep.notes)
    }

    /// Present the Quick Add sheet modally and return the created opportunity's
    /// id (nil if cancelled or no opportunity was named).
    private func runQuickAddForOpportunity() -> String? {
        MainActor.assumeIsolated {
            var result: String?
            let controller = NSHostingController(rootView: QuickAddSheet(store: CatalogStore.shared) { oppID in
                result = oppID
                NSApp.stopModal()
            })
            let window = NSWindow(contentViewController: controller)
            window.title = "Quick Add"
            window.styleMask = [.titled]
            NSApp.runModal(for: window)
            window.orderOut(nil)
            return result
        }
    }

    /// Simple name prompt for the quick-add catalog entries.
    private func promptNewCatalogName(_ title: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Name"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// Accessory view for the start dialog: a catalog-link popup, a template
    /// popup (shapes the summary), an optional agenda field, and a live-brief switch.
    private final class StartAccessory: NSView {
        let catalog = NSPopUpButton(frame: .zero, pullsDown: false)
        let search = NSSearchField(frame: .zero)
        let picker = NSPopUpButton(frame: .zero, pullsDown: false)
        let agendaField = NSTextField(frame: .zero)
        let liveBrief = NSSwitch(frame: .zero)
        let prepCard = NSSwitch(frame: .zero)
        let prepLabel = NSTextField(labelWithString: "Show prep card")

        /// Full link options (No link, org/opp rows, quick-add). The popup is
        /// rebuilt from this, filtered by the search field, so the list stays
        /// usable as the Catalog grows.
        var allOptions: [(title: String, repr: String)] = []

        /// Repopulate the link popup, keeping "No link" and the quick-add rows
        /// while narrowing the org/opportunity rows to those matching `filter`.
        func rebuildCatalogMenu(filter: String) {
            let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
            let prevRepr = catalog.selectedItem?.representedObject as? String

            // Keep an entity row only when it matches; leave fixed rows alone.
            var shown = allOptions.filter { opt in
                let isEntity = opt.repr.hasPrefix("opp:") || opt.repr.hasPrefix("org:")
                return !isEntity || q.isEmpty || opt.title.lowercased().contains(q)
            }
            // Collapse separators left dangling by filtering.
            var cleaned: [(title: String, repr: String)] = []
            for opt in shown where !(opt.repr == "__sep__" && (cleaned.isEmpty || cleaned.last?.repr == "__sep__")) {
                cleaned.append(opt)
            }
            if cleaned.last?.repr == "__sep__" { cleaned.removeLast() }
            shown = cleaned

            catalog.removeAllItems()
            catalog.menu?.autoenablesItems = false
            for opt in shown {
                if opt.repr == "__sep__" { catalog.menu?.addItem(.separator()); continue }
                let item = NSMenuItem(title: opt.title, action: nil, keyEquivalent: "")
                item.representedObject = opt.repr
                catalog.menu?.addItem(item)
            }
            if let prevRepr, let item = catalog.menu?.items.first(where: { ($0.representedObject as? String) == prevRepr }) {
                catalog.select(item)
            }
            catalogChanged()
        }

        @objc func searchChanged() { rebuildCatalogMenu(filter: search.stringValue) }

        /// The prep card only makes sense with a catalog link — enable the
        /// switch (and un-dim its label) only when an org/opportunity is chosen.
        @objc func catalogChanged() {
            let repr = catalog.selectedItem?.representedObject as? String ?? ""
            let linked = !repr.isEmpty && repr != "__sep__"
            prepCard.isEnabled = linked
            prepLabel.textColor = linked ? .labelColor : .tertiaryLabelColor
        }
    }

    /// The catalog entity to link the resulting note to (chosen at start).
    /// kind is "opp" or "org".
    private var meetingCatalogTarget: (kind: String, id: String)?

    /// Build the start-dialog accessory. An accessory view without explicit
    /// frames renders but doesn't receive clicks in NSAlert, so everything is
    /// laid out with explicit frames.
    private static func makeStartAccessory(selectedID: String, catalogOptions: [(title: String, repr: String)]) -> StartAccessory {
        let width: CGFloat = 300
        // Consistent vertical rhythm: a caption sits `capGap` above its control,
        // and groups are separated by `groupGap`. Everything is laid out top-down
        // with a cursor so the spacing stays even and easy to retune.
        let capH: CGFloat = 15, popH: CGFloat = 26, fieldH: CGFloat = 44, rowH: CGFloat = 22
        let capGap: CGFloat = 3, groupGap: CGFloat = 14, rowGap: CGFloat = 6
        let height = capH + capGap + popH + rowGap + popH + groupGap   // link: caption + search + popup
                   + capH + capGap + popH + groupGap
                   + capH + capGap + fieldH + groupGap
                   + rowH + rowGap + rowH
        let container = StartAccessory(frame: NSRect(x: 0, y: 0, width: width, height: height))

        // Distance consumed from the top edge; `place` reserves the next element
        // and returns its bottom-left-origin y.
        var top: CGFloat = 0
        func place(_ h: CGFloat) -> CGFloat {
            let y = height - top - h
            top += h
            return y
        }
        func caption(_ text: String) {
            let field = NSTextField(labelWithString: text)
            field.frame = NSRect(x: 0, y: place(capH), width: width, height: capH)
            field.font = .boldSystemFont(ofSize: 11)
            field.textColor = .secondaryLabelColor
            container.addSubview(field)
            top += capGap
        }

        // Catalog link (top) — file this meeting's note under an opportunity or
        // org. A search field narrows the list as the Catalog grows.
        caption("Link to (optional)")
        let search = container.search
        search.frame = NSRect(x: 0, y: place(popH), width: width, height: popH)
        search.placeholderString = "Search organisations & opportunities…"
        search.sendsWholeSearchString = false
        search.target = container
        search.action = #selector(StartAccessory.searchChanged)
        container.addSubview(search)
        top += rowGap

        let catalog = container.catalog
        catalog.frame = NSRect(x: 0, y: place(popH), width: width, height: popH)
        catalog.target = container
        catalog.action = #selector(StartAccessory.catalogChanged)
        container.allOptions = catalogOptions
        container.rebuildCatalogMenu(filter: "")
        container.addSubview(catalog)
        top += groupGap

        // Meeting type (middle) — shapes the summary.
        caption("Meeting type")
        let picker = container.picker
        picker.frame = NSRect(x: 0, y: place(popH), width: width, height: popH)
        // Grouped: a disabled section header per category, then its templates.
        // autoenablesItems must be off or the menu re-enables the headers,
        // making them look pickable (and one can show as the selection).
        picker.menu?.autoenablesItems = false
        for group in AppSettings.shared.groupedTemplates {
            let header = NSMenuItem(title: group.title, action: nil, keyEquivalent: "")
            header.isEnabled = false
            picker.menu?.addItem(header)
            for template in group.templates {
                let item = NSMenuItem(title: template.displayName, action: nil, keyEquivalent: "")
                item.indentationLevel = 1
                item.representedObject = template.id
                picker.menu?.addItem(item)
            }
        }
        // Select the stored template, else fall back to the first real item so
        // the popup never rests on a header.
        let match = picker.menu?.items.first { ($0.representedObject as? String) == selectedID }
            ?? picker.menu?.items.first { $0.representedObject != nil }
        if let match { picker.select(match) }
        container.addSubview(picker)
        top += groupGap

        // Agenda (optional) — drives the end-of-meeting coverage check.
        caption("Agenda")
        let field = container.agendaField
        field.frame = NSRect(x: 0, y: place(fieldH), width: width, height: fieldH)
        field.placeholderString = "Optional — separate items with commas"
        field.usesSingleLineMode = false
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.lineBreakMode = .byWordWrapping
        field.font = .systemFont(ofSize: 12)
        container.addSubview(field)
        top += groupGap

        // Live brief (bottom) — per-meeting choice, defaulting to the global
        // setting, as a Settings-style row: label left, switch right. Hard-
        // disabled when it couldn't run anyway (local-only / no key) so the
        // dialog never offers something that silently does nothing.
        let settings = AppSettings.shared
        let canRun = !settings.localOnlyMode && KeychainService.groqAPIKey() != nil
        let rowY = place(rowH)
        let live = container.liveBrief
        live.controlSize = .mini
        live.sizeToFit()
        live.frame = NSRect(x: width - live.frame.width,
                            y: rowY + (rowH - live.frame.height) / 2,
                            width: live.frame.width, height: live.frame.height)
        live.state = (canRun && settings.liveAssistantEnabled) ? .on : .off
        live.isEnabled = canRun

        let liveLabel = NSTextField(labelWithString: "Show live brief")
        liveLabel.frame = NSRect(x: 0, y: rowY + (rowH - 16) / 2,
                                 width: width - live.frame.width - 8, height: 16)
        liveLabel.font = .systemFont(ofSize: 12)
        liveLabel.textColor = canRun ? .labelColor : .tertiaryLabelColor
        let tip = canRun
            ? "Floating in-meeting brief (TL;DR, actions, agenda coverage). Defaults to your global setting; applies to this meeting only."
            : settings.localOnlyMode
                ? "Unavailable in local-only mode — the live brief needs the cloud."
                : "Add a Groq API key to use the live brief."
        live.toolTip = tip
        liveLabel.toolTip = tip
        container.addSubview(liveLabel)
        container.addSubview(live)

        // Prep card (below live brief) — show recent notes for the linked
        // org/opp when this meeting starts. On by default; only ever appears
        // when a link is chosen and it has prior notes.
        top += rowGap
        let prepRowY = place(rowH)
        let prep = container.prepCard
        prep.controlSize = .mini
        prep.sizeToFit()
        prep.frame = NSRect(x: width - prep.frame.width,
                            y: prepRowY + (rowH - prep.frame.height) / 2,
                            width: prep.frame.width, height: prep.frame.height)
        prep.state = AppSettings.shared.meetingPrepCard ? .on : .off
        let prepLabel = container.prepLabel
        prepLabel.frame = NSRect(x: 0, y: prepRowY + (rowH - 16) / 2,
                                 width: width - prep.frame.width - 8, height: 16)
        prepLabel.font = .systemFont(ofSize: 12)
        let prepTip = "When linked to an org/opportunity, pops a panel of its recent notes as the meeting starts. Applies to this meeting only."
        prep.toolTip = prepTip
        prepLabel.toolTip = prepTip
        container.addSubview(prepLabel)
        container.addSubview(prep)

        // Set the prep switch's initial enabled state from the default link.
        container.catalogChanged()

        return container
    }

    /// Fill a popup with "Unfiled", top-level projects (children indented), and
    /// "➕ New Project…". Type-to-jump gives quick search.
    /// Split a comma / newline / semicolon-separated agenda string into items.
    private static func parseAgenda(_ raw: String) -> [String] {
        raw.components(separatedBy: CharacterSet(charactersIn: ",\n;"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
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
            Task { @MainActor in await confirmEndAndStopMeeting() }
        }
    }

    // MARK: - Meeting Mode

    @objc private func toggleMeetingMode() {
        if appState.isMeetingMode {
            Task { @MainActor in await confirmEndAndStopMeeting() }
        } else {
            promptTemplateAndStartMeeting()
        }
    }

    /// "Ask before it ends": when the user deliberately ends a meeting, warn
    /// about anything still open — the user's uncovered agenda items AND any
    /// dynamically-discovered topics raised but left unresolved — and offer to
    /// keep recording. Stops straight away if there's nothing outstanding.
    @MainActor
    private func confirmEndAndStopMeeting() async {
        guard !endCoverageChecking else { return }

        let assistant = LiveMeetingAssistant.shared
        var uncovered: [String]
        if assistant.isActive {
            // Reuse the live panel's accumulated coverage (user ticks + the
            // discovered topics and their resolved state) — no extra model call.
            uncovered = assistant.coverageSnapshot.filter { !$0.covered }
                .map { $0.dynamic ? "\($0.text) (raised, unresolved)" : $0.text }
            Log.meeting.info("🔎 End-coverage (live): flagged=\(uncovered.count)")
        } else {
            // No live panel — do a one-shot read, if there's a cloud path and content.
            let settings = AppSettings.shared
            let transcript = meetingNotes.currentFilePath.flatMap { meetingNotes.transcriptText(of: $0) } ?? ""
            let spoken = Self.dialogueLength(of: transcript)
            guard !settings.localOnlyMode, KeychainService.groqAPIKey() != nil, spoken > 200 else {
                Log.meeting.info("⏭ End-coverage skipped (local=\(settings.localOnlyMode), spoken=\(spoken))")
                stopMeetingMode(); return
            }
            endCoverageChecking = true
            meetingModeMenuItem?.title = "Checking coverage…"
            let status = await textPolisher.agendaStatus(
                userAgenda: meetingAgenda,
                transcript: transcript.trimmingCharacters(in: .whitespacesAndNewlines),
                preferFast: false)
            endCoverageChecking = false
            meetingModeMenuItem?.title = appState.isMeetingMode ? "End Meeting" : "Start Meeting"
            let userUncovered = zip(meetingAgenda, status.userCovered).filter { !$0.1 }.map { $0.0 }
            let openTopics = status.newTopics.map { "\($0) (raised, unresolved)" }
            uncovered = userUncovered + openTopics
            Log.meeting.info("🔎 End-coverage (model): flagged=\(uncovered.count)")
        }

        // The meeting may have been stopped another way while we were checking.
        guard appState.isMeetingMode else { return }
        guard !uncovered.isEmpty else { stopMeetingMode(); return }

        let alert = NSAlert()
        alert.messageText = "Before you end this meeting"
        alert.informativeText = "These points still look open:\n\n" + uncovered.map { "•  \($0)" }.joined(separator: "\n")
        alert.addButton(withTitle: "Keep Recording")
        alert.addButton(withTitle: "End Anyway")
        alert.alertStyle = .informational
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() != .alertFirstButtonReturn {
            stopMeetingMode()   // "End Anyway"
        }
    }

    private var endCoverageChecking = false

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

        // Prime Whisper with the proper nouns for this meeting (linked entity,
        // its people, taught voices) so names transcribe right from the start.
        GroqService.sessionGlossary = buildSessionGlossary(for: meetingCatalogTarget)

        // Reset the speaker profiles for the new session (safe to touch
        // directly — the capture callbacks haven't started yet)
        speakerProfiler.reset()

        // Live in-meeting brief (opt-in; reads the growing notes file).
        LiveMeetingAssistant.shared.start(
            transcriptProvider: { [weak self] in
                guard let url = self?.meetingNotes.currentFilePath else { return nil }
                return self?.meetingNotes.transcriptText(of: url)
            },
            template: settings.selectedTemplate,
            agenda: meetingAgenda,
            enabled: meetingLiveBrief)

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
        // Hand the agenda to the finalizer (for the notes' Agenda section)
        // before clearing it for the next meeting.
        let agendaForNotes = meetingAgenda
        meetingAgenda = []
        // Snapshot the catalog target NOW, before the async finalize below.
        // It's a shared field; a meeting started during the ~20s finalize wait
        // would otherwise overwrite it, mislinking this note (or dropping the
        // link entirely). Clearing it here also prevents leaking into the next.
        let catalogTargetForNotes = meetingCatalogTarget
        meetingCatalogTarget = nil

        // Session glossary is per-meeting — clear it so it can't bias the next
        // meeting's transcription (or dictation) with stale names.
        GroqService.sessionGlossary = ""

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
                self.finalizeMeetingNotes(startedAt: start, agenda: agendaForNotes,
                                          catalogTarget: catalogTargetForNotes)
            }
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.appState.isMeetingMode = false
            self.appState.meetingCaption = ""
            self.appState.isSpeakerActive = false
            LiveMeetingAssistant.shared.stop()
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
                let text = try await transcribeWithFallback(captured, context: self.meetingNotes.promptContext)
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
                    let text = try await self.transcribeWithFallback(segment.audio, context: self.meetingNotes.promptContext)
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
                let text = try await transcribeWithFallback(segment.audio, context: meetingNotes.promptContext)
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
                let text = try await transcribeWithFallback(capturedAudio, context: self.meetingNotes.promptContext)
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

    // MARK: - Menus

    /// Rebuilds the Notes submenu (and refreshes the Main menu) on open.
    func menuNeedsUpdate(_ menu: NSMenu) {
        switch menu.title {
        case "Main":
            let stats = UsageStats.shared
            let weekMeetings = stats.meetingsThisWeek(in: settings.notesFolder)
            var statsLine = "\(weekMeetings) meeting\(weekMeetings == 1 ? "" : "s") this week · \(stats.dictationCount) dictations"
            // Surface the running cost estimate when there's been any spend.
            if !settings.localOnlyMode, stats.estimatedCostUSD >= 0.01 {
                statsLine += " · ~\(UsageStats.currency(stats.estimatedCostUSD))"
                // Flag when this month's spend has crossed the soft budget.
                if stats.isOverBudget {
                    statsLine += " ⚠️ over budget"
                }
            }
            statsMenuItem?.title = statsLine
            // Pause only makes sense mid-meeting — hide it otherwise.
            pauseMenuItem?.isHidden = !appState.isMeetingMode
            // Live Brief show/hide — only while its panel is running.
            let live = LiveMeetingAssistant.shared
            // Available whenever a meeting is running and the brief could run —
            // so it can be started mid-meeting even if it began switched off.
            let canRunLive = !settings.localOnlyMode && KeychainService.groqAPIKey() != nil
            liveBriefMenuItem?.isHidden = !(appState.isMeetingMode && canRunLive)
            liveBriefMenuItem?.title = live.isActive
                ? (live.visible ? "Hide Live Brief" : "Show Live Brief")
                : (live.ended ? "Resume Live Brief" : "Start Live Brief")
            // "Turn Off" only makes sense while it's actively running.
            liveBriefEndMenuItem?.isHidden = !live.isActive
            // Error banner — visible only when there's a recent failure.
            if let message = appState.lastError {
                errorMenuItem?.isHidden = false
                errorMenuItem?.title = "\(message)  (click to dismiss)"
            } else {
                errorMenuItem?.isHidden = true
            }

        case "Notes & History":
            menu.removeAllItems()

            // Current (or latest) meeting notes — same action as ⌃⌥N —
            // and today's quick notes, the two "get me to my notes" verbs.
            let openItem = NSMenuItem(title: appState.isMeetingMode ? "Open Current Meeting Notes" : "Open Latest Meeting Notes",
                                      action: #selector(openNotes), keyEquivalent: "n")
            openItem.keyEquivalentModifierMask = [.control, .option]
            openItem.target = self
            menu.addItem(openItem)
            // Title reflects what actually opens: today's file if it exists,
            // otherwise the most recent quick-notes file, otherwise the folder.
            let hasTodayQuickNotes = FileManager.default.fileExists(
                atPath: MeetingNotesWriter.todaysQuickNotesURL().path)
            let quickNotesTitle = hasTodayQuickNotes
                ? "Open Today's Quick Notes"
                : (MeetingNotesWriter.latestQuickNotesFile() != nil ? "Open Latest Quick Notes" : "Open Quick Notes Folder")
            let quickNotesItem = NSMenuItem(title: quickNotesTitle, action: #selector(openTodaysQuickNotes), keyEquivalent: "")
            quickNotesItem.target = self
            menu.addItem(quickNotesItem)
            menu.addItem(NSMenuItem.separator())

            // Only the 5 most recent here — the Catalog (below) is the full,
            // searchable browser.
            let files = MeetingNotesWriter.allMeetingFiles(under: settings.notesFolder).prefix(5)

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
                    let header = NSMenuItem(title: DateDisplay.day(day), action: nil, keyEquivalent: "")
                    header.isEnabled = false
                    menu.addItem(header)
                }
                let item = NSMenuItem(title: time, action: #selector(openMeetingFile(_:)), keyEquivalent: "")
                item.indentationLevel = 1
                item.target = self
                item.representedObject = file
                menu.addItem(item)
            }
            // (Catalog has its own top-level menu entry — no duplicate here.)
            menu.addItem(NSMenuItem.separator())
            let renameItem = NSMenuItem(title: "Rename Speakers…", action: #selector(showRenameSpeakers), keyEquivalent: "")
            renameItem.target = self
            menu.addItem(renameItem)
            let folderItem = NSMenuItem(title: "Open Notes Folder…", action: #selector(openNotesFolder), keyEquivalent: "")
            folderItem.target = self
            menu.addItem(folderItem)

        default:
            break
        }
    }

    @objc private func clearDictationHistory() {
        dictationHistory.removeAll()
    }

    /// Open a meeting note in the in-app viewer/editor (which itself offers
    /// "Open in Default App", "Reveal in Finder", and "Draft Follow-up").
    @objc private func openMeetingFile(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NotesViewerWindowController.present(fileURL: url)
    }


    private var renameSpeakersWindowController: RenameSpeakersWindowController?

    /// Rename Them / Them 2 to real names — per meeting. Opens with the live
    /// meeting preselected when one is running; renames touch only the chosen
    /// file, and live-session overrides apply only to the current meeting.
    @objc private func showRenameSpeakers() {
        presentRenameSpeakers(preselect: nil)
    }

    /// From the notes viewer: rename speakers with that note preselected.
    @objc private func renameSpeakersForFile(_ note: Notification) {
        presentRenameSpeakers(preselect: note.object as? URL)
    }

    private func presentRenameSpeakers(preselect: URL?) {
        renameSpeakersWindowController = RenameSpeakersWindowController(
            liveFile: meetingNotes.currentFilePath,
            preselect: preselect,
            onRename: { [weak self] old, new, file in
                guard let self else { return }
                // Teach the voice identity: if we have this meeting's fingerprint
                // for the renamed label, save it under the new name so this voice
                // is auto-labeled in future meetings.
                if let fp = VoiceIdentityStore.shared.fingerprint(forLabel: old, file: file.path) {
                    VoiceIdentityStore.shared.remember(name: new, pitch: fp.pitch, zcr: fp.zcr)
                }
                // Keep a live meeting using the new name for later segments.
                if self.meetingNotes.currentFilePath == file {
                    self.meetingNotes.setNameOverride(new, replacing: old)
                }
            })
        renameSpeakersWindowController?.bringToFront()
    }

    /// Cache this meeting's voice fingerprints and auto-rename any speaker whose
    /// voice matches a saved identity (taught by a previous rename).
    private func applyVoiceIdentities(to fileURL: URL) {
        let snaps = speakerProfiler.snapshot()
        guard !snaps.isEmpty else { return }
        VoiceIdentityStore.shared.cacheSnapshot(snaps, forFile: fileURL.path)
        for s in snaps {
            guard let name = VoiceIdentityStore.shared.match(pitch: s.pitch, zcr: s.zcr),
                  name != s.label else { continue }
            MeetingNotesWriter.renameSpeaker(from: s.label, to: name, in: fileURL)
        }
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


    /// Surface a non-fatal error: remember it for the menu and post a
    /// notification. Safe to call from any thread.
    private func reportError(_ message: String) {
        Log.app.error("❗️ \(message)")
        DiagnosticsLog.shared.record(message)
        Task { @MainActor in
            self.appState.lastError = message
            if self.settings.errorNotifications {
                NotificationManager.shared.notifyError(message)
            }
        }
    }

    /// Clear the current surfaced error (from the menu).
    @objc private func dismissLastError() {
        appState.lastError = nil
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
    /// The most recent surfaced error, shown in the menu until dismissed.
    var lastError: String?
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
