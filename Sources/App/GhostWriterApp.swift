import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - App Delegate

/// Manages the app lifecycle, permission checks, hotkey registration, and the floating overlay.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    // MARK: - Properties

    var statusItem: NSStatusItem?
    var overlayPanel: NSPanel?
    private var overlayHostingView: NSHostingView<GlowOverlayView>?
    private var apiKeyWindowController: APIKeyWindowController?
    private var onboardingWindowController: OnboardingWindowController?
    private var settingsWindowController: SettingsWindowController?
    var renameSpeakersWindowController: RenameSpeakersWindowController?
    var meetingModeMenuItem: NSMenuItem?

    // Settings (UserDefaults-backed, live)
    let settings = AppSettings.shared

    // Core services
    private let permissionGuard = PermissionGuard()
    private let hotkeyManager = HotkeyManager()
    private let audioCapture = AudioCapture()
    let systemAudioCapture = SystemAudioCapture()
    let meetingDetector = MeetingDetector()
    private let voiceActivityDetector = VoiceActivityDetector()
    private let groqService = GroqService()
    let textPolisher = TextPolisher()
    private let appDetector = AppDetector()
    private let textInjector = TextInjector()
    private let offlineTranscriber = OfflineTranscriber()

    // Shared state
    let appState = AppState()

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
    let meetingQueue = DispatchQueue(label: "com.ghostwriter.meeting", qos: .userInteractive)
    var meetingSpeechBuffer = Data()
    var meetingLastVoiceTime: Date?
    var meetingSegmentStart: Date?
    var meetingSilenceDebounce: TimeInterval { settings.silenceDebounce }
    var meetingMaxSegmentSeconds: TimeInterval { settings.maxSegmentSeconds }

    // Meeting mode state — microphone (self), accessed on micMeetingQueue
    let micMeetingQueue = DispatchQueue(label: "com.ghostwriter.meeting.mic", qos: .userInteractive)
    var micMeetingSpeechBuffer = Data()
    var micMeetingLastVoiceTime: Date?
    var micMeetingSegmentStart: Date?
    let micCapture = AudioCapture()

    // Echo suppression (half-duplex): when using the built-in speaker instead of
    // headphones, the mic picks up the remote party's voice as acoustic echo and
    // mislabels it "You". We gate the mic while the speaker is (recently) active.
    let echoGateLock = NSLock()
    var speakerLastActiveTime: Date?
    var echoGateWindow: TimeInterval { settings.echoGateWindow }  // mute mic for this long after speaker audio

    // Meeting notes
    let meetingNotes = MeetingNotesWriter()
    /// Optional per-meeting audio recorder (retention safety net).
    var audioRetainer: AudioRetainer?
    var meetingStartTime: Date?
    var meetingTimer: Timer?
    /// Re-entrancy guard for the async end-of-meeting coverage check.
    var endCoverageChecking = false
    /// One prompt is enough: while a start dialog is up, hotkeys and the detector
    /// keep running — this flag stops a second dialog from stacking.
    var meetingStartPromptActive = false
    /// Agenda items entered at meeting start (may be empty) — drives the live
    /// coverage checklist and the end-of-meeting "did we cover it?" check.
    var meetingAgenda: [String] = []
    /// Per-meeting live-brief choice from the start dialog (nil → global setting).
    var meetingLiveBrief: Bool?
    /// The catalog entity to link the resulting note to (kind "project" or "org").
    var meetingCatalogTarget: (kind: String, id: String)?

    // Experimental diarization (accessed on meetingQueue): voice-fingerprint
    // clustering (pitch + timbre) assigns remote segments to Them / Them 2 / …
    let speakerProfiler = SpeakerProfiler()

    // Retry queue (main thread): meeting segments whose transcription failed —
    // a network blip should not silently drop a piece of the meeting.
    struct PendingSegment {
        let audio: Data
        let speaker: String
        let capturedAt: Date
        var attempts: Int
    }
    var retryQueue: [PendingSegment] = []
    var retryTimer: Timer?
    private var digestTimer: Timer?
    private var backupTimer: Timer?
    var maxRetryAttempts: Int { max(1, settings.retryMaxAttempts) }

    // Whisper hallucinates these phrases on short/quiet audio — discard them.
    let whisperHallucinations: Set<String> = [
        "thank you.", "thanks for watching.", "thanks for watching", "thank you",
        "you", ".", " ", "of the", "the", "a", "i", "bye.", "bye",
        "[music]", "[applause]", "[silence]", "♪", "..."
    ]

    // In-flight transcription counter: meeting shutdown waits for these so the
    // last spoken words land in the notes before the file is finalized.
    private let pendingLock = NSLock()
    private var pendingTranscriptionCount = 0
    func beginPendingTranscription() {
        pendingLock.lock(); pendingTranscriptionCount += 1; pendingLock.unlock()
    }
    func endPendingTranscription() {
        pendingLock.lock(); pendingTranscriptionCount -= 1; pendingLock.unlock()
    }
    var pendingTranscriptions: Int {
        pendingLock.lock(); defer { pendingLock.unlock() }
        return pendingTranscriptionCount
    }

    // Dictation history (main thread): last N transcriptions for re-inject/recall
    var dictationHistory: [(date: Date, text: String, duration: TimeInterval)] = []
    private var pttStartTime: Date?
    private var dictationTimer: Timer?

    // Pause (⌃⌥P): gate transcription without ending the session.
    // Read from the audio queues, written on main — guarded by a lock.
    private let pauseLock = NSLock()
    private var meetingTranscriptionPaused = false
    var isTranscriptionPaused: Bool {
        pauseLock.lock(); defer { pauseLock.unlock() }
        return meetingTranscriptionPaused
    }
    func setTranscriptionPaused(_ value: Bool) {
        pauseLock.lock(); meetingTranscriptionPaused = value; pauseLock.unlock()
    }
    var pauseMenuItem: NSMenuItem?
    var liveBriefMenuItem: NSMenuItem?
    var liveBriefEndMenuItem: NSMenuItem?
    var statsMenuItem: NSMenuItem?
    var errorMenuItem: NSMenuItem?

    // Support logic
    private var hasPromptedForPermissions = false

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        installEditMenu()
        setupStatusItem()
        setupOverlayPanel()
        setupHotkeyCallbacks()

        // Warm the Groq model catalog so model choices resolve against what
        // actually exists (see ModelResolver) before the first meeting.
        Task { await ModelResolver.shared.refresh() }
        NotificationCenter.default.addObserver(
            forName: ModelResolver.didAutoSwitch, object: nil, queue: .main) { note in
            guard let from = note.userInfo?["from"] as? String,
                  let to = note.userInfo?["to"] as? String else { return }
            NotificationManager.shared.notifyModelSwitched(from: from, to: to)
        }

        NotificationCenter.default.addObserver(self, selector: #selector(onAPIKeySaved), name: NSNotification.Name("APIKeySaved"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(showAPIKeyWindow), name: .showAPIKeyWindow, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(onSettingsChanged), name: .settingsDidReset, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(resetPermissions), name: .resetAllPermissions, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(clearDictationHistory), name: .dictationHistoryDisabled, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(renameSpeakersForFile(_:)), name: .renameSpeakersForFile, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(showDigestWindow), name: .openDigest, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(openNoteFromNotification(_:)), name: .openNoteFile, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(revealNoteInCatalog(_:)), name: .revealNoteInCatalog, object: nil)

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
        startBackupScheduler()

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

    // MARK: - Backup scheduler

    /// Check hourly (and shortly after launch) whether today's automatic backup
    /// is due. Opportunistic rather than clock-scheduled: the first awake hour
    /// on a new day triggers it, so a Mac asleep at midnight isn't skipped.
    private func startBackupScheduler() {
        backupTimer?.invalidate()
        backupTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkBackupDue() }   // timer fires on the main run loop
        }
        // A short delay so first-launch UI/permission prompts settle first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            MainActor.assumeIsolated { self?.checkBackupDue() }
        }
    }

    /// Run today's automatic backup if enabled, not already done today, and the
    /// app is idle — never snapshot mid-meeting, which could capture a torn
    /// `Catalog.json`; it simply retries on the next hourly tick.
    @MainActor
    private func checkBackupDue() {
        guard settings.autoBackupEnabled else { return }
        guard !settings.hasBackedUpToday else { return }
        guard !appState.isMeetingMode else { return }
        BackupService.runAutomaticBackup()
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

        // First-run welcome tour — once permission prompts have settled.
        if !AppSettings.shared.onboardingCompleted {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.showOnboarding()
            }
        }
    }

    /// Open the welcome tour (auto-shown once on first run; re-openable from the menu).
    @objc private func showOnboarding() {
        if onboardingWindowController == nil {
            onboardingWindowController = OnboardingWindowController()
        }
        onboardingWindowController?.showAndActivate()
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

    // MARK: - Audio File Import

    private var importWindowController: ImportAudioWindowController?

    /// Menu action / drag-drop entry: open the Import Audio window, optionally
    /// pre-loading dropped files. Transcription, note-writing and Catalog
    /// linking all run inside the window via AudioImportService.
    @objc private func importAudioFile() { showAudioImport() }

    func showAudioImport(urls: [URL] = []) {
        MainActor.assumeIsolated {
            if importWindowController == nil {
                importWindowController = ImportAudioWindowController()
            }
            if !urls.isEmpty { AudioImportService.shared.add(urls) }
            importWindowController?.bringToFront()
        }
    }

    private var catalogWindowController: CatalogWindowController?

    /// Open the Catalog — organisations, people, projects, tags over the notes.
    @objc private func showCatalog() {
        if catalogWindowController == nil {
            catalogWindowController = CatalogWindowController()
        }
        catalogWindowController?.bringToFront()
    }

    /// Open the Catalog and switch it to the Notes section — the single, full,
    /// searchable notes browser (the menu's Recent Notes is only quick jumps).
    @objc func showCatalogNotes() {
        showCatalog()
        // Post after the window/observer exists so the section switch isn't missed.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .showCatalogNotes, object: nil)
        }
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

    @objc func showAPIKeyWindow() {
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

    /// Lowercased letter to display next to a menu item for a remappable ⌃⌥
    /// shortcut (display-only — the real hotkey is handled by the CGEventTap).
    func shortcutLetter(_ shortcut: GlobalShortcut) -> String {
        ShortcutKeys.label(for: AppSettings.shared.shortcutKeyCode(for: shortcut)).lowercased()
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
        let meetingItem = NSMenuItem(title: "Start Meeting", action: #selector(toggleMeetingMode), keyEquivalent: shortcutLetter(.meetingMode))
        meetingItem.keyEquivalentModifierMask = [.control, .option]
        meetingItem.image = NSImage(systemSymbolName: "person.2.wave.2", accessibilityDescription: nil)
        meetingItem.target = self
        menu.addItem(meetingItem)
        self.meetingModeMenuItem = meetingItem

        let pauseItem = NSMenuItem(title: "Pause Meeting", action: #selector(togglePauseTranscription), keyEquivalent: shortcutLetter(.pauseMeeting))
        pauseItem.keyEquivalentModifierMask = [.control, .option]
        pauseItem.image = NSImage(systemSymbolName: "pause.circle", accessibilityDescription: nil)
        pauseItem.target = self
        menu.addItem(pauseItem)
        self.pauseMenuItem = pauseItem

        // Quick Note sits with the capture actions — Start Meeting, Pause, and
        // Quick Note are all "record something now" verbs sharing the ⌃⌥ hotkey
        // family, so they stay contiguous.
        let quickNoteItem = NSMenuItem(title: "Quick Note", action: #selector(toggleQuickNote), keyEquivalent: shortcutLetter(.quickNote))
        quickNoteItem.keyEquivalentModifierMask = [.control, .option]
        quickNoteItem.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: nil)
        quickNoteItem.target = self
        menu.addItem(quickNoteItem)
        self.quickNoteMenuItem = quickNoteItem

        // Transcribe an existing audio file — an ingest verb that *creates* a
        // note, so it belongs with the capture actions, not the browse list.
        let importItem = NSMenuItem(title: "Transcribe Audio File…", action: #selector(importAudioFile), keyEquivalent: "")
        importItem.image = NSImage(systemSymbolName: "waveform.badge.plus", accessibilityDescription: nil)
        importItem.target = self
        menu.addItem(importItem)

        // Split the Live Brief *display* toggles from the capture verbs above —
        // they act on an already-running meeting's panel, a distinct concern.
        menu.addItem(NSMenuItem.separator())

        // Live Brief is a display toggle (show/hide the floating panel), not a
        // capture verb. Hidden unless a meeting's live assistant is active
        // (see menuNeedsUpdate).
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

        // ── Browse ──────────────────────────────────────────────
        // Catalog is the primary organiser and the main browse surface, so it
        // leads the cluster; then the quick file-open submenu, then the raw
        // dictation archive.
        let catalogItem = NSMenuItem(title: "Catalog…", action: #selector(showCatalog), keyEquivalent: "")
        catalogItem.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil)
        catalogItem.target = self
        menu.addItem(catalogItem)

        // Notes submenu — current notes, quick notes, recent meetings, folder —
        // rebuilt on open via menuNeedsUpdate. Labelled "Recent Notes" to signal
        // it's the quick day-by-day file opener, distinct from the Catalog browse.
        let meetingNotesItem = NSMenuItem(title: "Recent Notes", action: nil, keyEquivalent: "")
        meetingNotesItem.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)
        let meetingNotesMenu = NSMenu(title: "Recent Notes")
        meetingNotesMenu.delegate = self
        meetingNotesItem.submenu = meetingNotesMenu
        menu.addItem(meetingNotesItem)

        let dictationsItem = NSMenuItem(title: "Dictations…", action: #selector(showDictations), keyEquivalent: "")
        dictationsItem.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)
        dictationsItem.target = self
        menu.addItem(dictationsItem)

        // ── Insights ────────────────────────────────────────────
        // AI-over-notes actions, set apart from the raw browse/archive items above.
        menu.addItem(NSMenuItem.separator())

        let digestItem = NSMenuItem(title: "Today's Digest…", action: #selector(showDigestWindow), keyEquivalent: "")
        digestItem.image = NSImage(systemSymbolName: "newspaper", accessibilityDescription: nil)
        digestItem.target = self
        menu.addItem(digestItem)

        let askItem = NSMenuItem(title: "Ask Anything…", action: #selector(showAskWindow), keyEquivalent: "")
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

        let welcomeItem = NSMenuItem(title: "Welcome to GhostWriter…", action: #selector(showOnboarding), keyEquivalent: "")
        welcomeItem.image = NSImage(systemSymbolName: "hand.wave", accessibilityDescription: nil)
        welcomeItem.target = self
        menu.addItem(welcomeItem)

        // Settings + Quit form one trailing utility group (HIG) — no separator
        // between them. Permissions/API key live inside Settings, not here.

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

    func positionOverlayPanel(_ panel: NSPanel) {
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

    /// Whether a dictation blob is worth uploading to Groq: it must contain
    /// voiced audio above the configured floor (unless the guard is disabled).
    /// Skips the wasted round-trip — and the Whisper hallucinations it invites —
    /// on recordings that are pure silence.
    private func dictationHasSpeech(_ audio: Data) -> Bool {
        guard settings.skipSilentDictation else { return true }
        return voiceActivityDetector.containsVoice(
            in: audio, aboveDBFS: settings.dictationSilenceThreshold)
    }

    private func finishQuickNote() {
        audioCapture.stop()
        let captured = audioBuffer
        audioBuffer = Data()
        endQuickNoteRecording()

        guard !captured.isEmpty, dictationHasSpeech(captured) else {
            if !captured.isEmpty { Log.dictation.debug("🔇 Quick note was silent — skipping upload") }
            appState.recordingState = .idle
            hideOverlayUnlessMeeting()
            return
        }
        appState.recordingState = .processing

        Task {
            do {
                let rawText = try await transcribeWithFallback(captured)
                let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, !whisperHallucinations.contains(trimmed.lowercased()) else {
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
                        Clipboard.plain(polished)
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


    /// The single transcription choke point for dictation, quick notes, and
    /// meetings. Local-only mode goes straight to on-device recognition; other-
    /// wise Groq first, falling back on-device when the network is down. The
    /// result is passed through optional redaction before anyone sees it.
    func transcribeWithFallback(_ audioData: Data, context: String = "") async throws -> String {
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
    func finalizeMeetingNotes(startedAt start: Date, agenda: [String] = [],
                                      catalogTarget: (kind: String, id: String)? = nil) {
        guard let fileURL = meetingNotes.lastCompletedFilePath else { return }

        let elapsed = Int(Date().timeIntervalSince(start))
        let duration = String(format: "%d:%02d", elapsed / 60, elapsed % 60)

        Task { [weak self] in
            guard let self else { return }

            // Link the note into the Catalog under the project/org chosen at
            // start (if any), creating its catalog row from the file path.
            await MainActor.run {
                guard let target = catalogTarget else { return }
                let store = CatalogStore.shared
                let rel = AppSettings.shared.relativePath(of: fileURL)
                let note = store.note(forRelativePath: rel,
                                      title: fileURL.deletingPathExtension().lastPathComponent,
                                      date: start)
                if target.kind == "project" { store.setProject(target.id, on: note.id, true) }
                else if target.kind == "org" { store.setOrg(target.id, on: note.id, true) }

                // Mirror the link into the note's front-matter so the file
                // itself carries who it's about (visible in Obsidian, and it
                // survives independently of the Catalog database).
                if AppSettings.shared.frontMatterEnabled {
                    var fields: [(key: String, value: String)] = []
                    if target.kind == "project", let proj = store.project(target.id) {
                        fields.append(("project", proj.name))
                        // Org sits above the project (walking the hierarchy).
                        if let org = store.org(forProject: proj.id) {
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

            // Re-runnable AI refinement (summary, key details, chapters,
            // agenda, mentions), shared with the manual retry in the notes
            // viewer — see MeetingRefinery.
            if let transcript = self.meetingNotes.transcriptText(of: fileURL) {
                let liveAgenda = await LiveMeetingAssistant.shared.coverageSnapshot
                // Ensure no in-flight live-assistant tick is still running before
                // the refinery fans out its own calls.
                await LiveMeetingAssistant.shared.quiesce()
                await MeetingRefinery.refine(
                    fileURL: fileURL, transcript: transcript,
                    options: .init(userAgenda: agenda, liveAgenda: liveAgenda, stripExisting: false),
                    onError: { self.reportError($0) })
            }

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

        let markdown = (fileURL.readText()) ?? ""
        let title = FrontMatter.title(in: markdown)
            ?? fileURL.deletingPathExtension().lastPathComponent
        let tags = FrontMatter.tags(in: markdown)
        let typeID = FrontMatter.field("gw_meeting_type", in: markdown)
        let meetingType = typeID.flatMap { id in
            AppSettings.shared.allTemplates.first { $0.id == id }?.displayName
        } ?? typeID

        // Resolve the org / project chain from the Catalog link.
        var org: String?, project: String?
        let store = CatalogStore.shared
        let rel = s.relativePath(of: fileURL)
        if let note = store.doc.notes.first(where: { $0.filePath == rel }) {
            if let projID = note.projectIDs.first, let proj = store.project(projID) {
                project = proj.name
                org = store.org(forProject: proj.id)?.name
            } else if let orgID = note.orgIDs.first {
                org = store.org(orgID)?.name
            }
        }

        let payload = EventDispatcher.MeetingFinishedPayload(
            title: title,
            file: fileURL.path,
            date: DateDisplay.iso8601.string(from: start),
            durationSeconds: durationSeconds,
            meetingType: meetingType,
            organisation: org,
            project: project,
            tags: tags)
        EventDispatcher.dispatch(payload)
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

    /// Front the Catalog window and select the given note inside it. The catalog
    /// window (and its `CatalogView` observer) may not exist yet, so we create it
    /// via `showCatalog()` first, then re-broadcast on the next runloop tick — by
    /// which point the view has subscribed — carrying the note id through.
    @objc private func revealNoteInCatalog(_ note: Notification) {
        guard let id = note.object as? String else { return }
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            self.showCatalog()
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .selectCatalogNote, object: id)
            }
        }
    }

    @objc func openNotes() {
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
                // Don't spend a Groq call on a chunk that's all silence.
                guard self.dictationHasSpeech(chunk) else {
                    Log.dictation.debug("🔇 Silent chunk — skipping upload")
                    return
                }
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
        hotkeyManager.recordingDidEnd()
        if !appState.isMeetingMode { overlayPanel?.orderOut(nil) }
        Log.dictation.debug("🎤 Dictation cancelled (Esc)")
    }

    private func stopRecordingAndProcess() {
        // PTT key-up fires even when key-down was refused (e.g. a quick note
        // owns the engine) — don't hijack the quick note's capture.
        guard !quickNoteActive else { return }
        hotkeyManager.recordingDidEnd()
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
                if !capturedAudio.isEmpty, dictationHasSpeech(capturedAudio) {
                    // Prime the final tail with the chunks already transcribed
                    // in this same dictation, so terms stay consistent.
                    let tail = try await transcribeWithFallback(capturedAudio, context: parts.joined(separator: " "))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !tail.isEmpty { parts.append(tail) }
                }
                let rawText = parts.joined(separator: " ")
                let rawTrimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !rawTrimmed.isEmpty, !whisperHallucinations.contains(rawTrimmed.lowercased()) else {
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

}
