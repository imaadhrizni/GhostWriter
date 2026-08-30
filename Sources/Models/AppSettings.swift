import Foundation
import Combine

// MARK: - App Settings
//
// UserDefaults-backed settings store. Every value has a default matching the
// previously hard-coded behavior, so a fresh install behaves identically.
// ObservableObject so SwiftUI views refresh when any value changes (incl. reset).

final class AppSettings: ObservableObject {

    static let shared = AppSettings()
    /// Backing store. `internal` (not private) so the `@Setting` property wrapper
    /// can read/write it via the enclosing-instance subscript.
    let defaults = UserDefaults.standard

    private init() { migrateDeprecatedModels() }

    /// Groq periodically decommissions models (a stored id then 404s on every
    /// call). Rewrite any persisted model setting that points at a now-removed
    /// id onto its recommended replacement, so upgrades self-heal.
    private func migrateDeprecatedModels() {
        // Groq-decommissioned model ids (per console.groq.com/docs/deprecations).
        // A stored id here 404s on every call, so heal it onto the role's current
        // default — which is role-appropriate (polishing → gpt-oss-120b,
        // lightweight → gpt-oss-20b), Groq's own recommended replacements. The
        // send() pipeline reads reasoning-model output, so gpt-oss is safe here.
        let deprecated: Set<String> = [
            "meta-llama/llama-4-scout-17b-16e-instruct",
            "meta-llama/llama-4-maverick-17b-128e-instruct",
            "qwen/qwen3-32b",
            "moonshotai/kimi-k2-instruct-0905",
            "moonshotai/kimi-k2-instruct",
            "llama-3.1-8b-instant",      // decommissioned 2026-08-16 → gpt-oss-20b
            "llama-3.3-70b-versatile",   // decommissioned 2026-08-16 → gpt-oss-120b
        ]
        for (key, replacement) in [(Key.polishingModel, Default.polishingModel),
                                   (Key.fastModel, Default.fastModel)] {
            if let cur = defaults.string(forKey: key), deprecated.contains(cur) {
                defaults.set(replacement, forKey: key)
            }
        }
    }

    // MARK: - API Endpoint

    /// Base URL of the OpenAI-compatible API (Groq by default). Point this at a
    /// proxy, an enterprise gateway, or a self-hosted OpenAI-compatible server.
    /// A trailing slash is trimmed; blank resets to the Groq default. All API
    /// clients (transcription, chat, model catalog, key check) read through here.
    var apiBaseURL: String {
        get {
            let raw = string(Key.apiBaseURL, Default.apiBaseURL)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmed = raw.hasSuffix("/") ? String(raw.dropLast()) : raw
            return trimmed.isEmpty ? Default.apiBaseURL : trimmed
        }
        set { set(newValue, Key.apiBaseURL) }
    }

    // MARK: - API Models

    /// Groq speech-to-text model used for dictation and meetings.
    @Setting(Key.transcriptionModel, Default.transcriptionModel) var transcriptionModel: String

    /// Groq LLM used to polish dictated text.
    @Setting(Key.polishingModel, Default.polishingModel) var polishingModel: String

    /// Cheap/fast model for lightweight, high-frequency tasks (live brief,
    /// tagging, query expansion, agenda coverage) — keeps cost and latency down.
    @Setting(Key.fastModel, Default.fastModel) var fastModel: String

    /// Whether the first-run welcome tour has been seen. Set when the tour is
    /// completed or skipped; drives the one-time auto-present on launch.
    var onboardingCompleted: Bool {
        get { bool(Key.onboardingCompleted, false) }
        set { set(newValue, Key.onboardingCompleted) }
    }

    // MARK: - Global shortcuts

    /// User overrides for the six ⌃⌥ global shortcuts, keyed by
    /// `GlobalShortcut.rawValue` → virtual key code. Only non-default bindings
    /// are stored; the modifier (⌃⌥) is fixed.
    private var shortcutOverrides: [String: Int] {
        get {
            guard let data = defaults.data(forKey: Key.shortcutOverrides),
                  let dict = try? JSONDecoder().decode([String: Int].self, from: data)
            else { return [:] }
            return dict
        }
        set {
            let data = try? JSONEncoder().encode(newValue)
            set(data as Any, Key.shortcutOverrides)
        }
    }

    /// The configured virtual key code for a global shortcut (its default if unset).
    func shortcutKeyCode(for shortcut: GlobalShortcut) -> Int {
        shortcutOverrides[shortcut.rawValue] ?? shortcut.defaultKeyCode
    }

    /// Rebind a global shortcut. Passing its default clears the override.
    func setShortcutKeyCode(_ code: Int, for shortcut: GlobalShortcut) {
        var dict = shortcutOverrides
        if code == shortcut.defaultKeyCode { dict[shortcut.rawValue] = nil }
        else { dict[shortcut.rawValue] = code }
        shortcutOverrides = dict
    }

    /// Reset every global shortcut to its default letter.
    func resetShortcutOverrides() { shortcutOverrides = [:] }

    /// Shortcuts whose key currently collides with another action (duplicate
    /// bindings), so the UI can warn — first match wins at dispatch time.
    var conflictingShortcutKeys: Set<Int> {
        var seen: [Int: Int] = [:]
        for s in GlobalShortcut.allCases { seen[shortcutKeyCode(for: s), default: 0] += 1 }
        return Set(seen.filter { $0.value > 1 }.keys)
    }

    // MARK: - Dictation

    /// CGEvent keycode of the push-to-talk modifier key.
    @Setting(Key.pttKeyCode, Default.pttKeyCode) var pttKeyCode: Int

    /// How the push-to-talk key activates recording: hold-to-talk, tap-to-lock
    /// (hold still works; a quick tap latches hands-free), or pure toggle.
    var pttActivation: PTTActivation {
        get { PTTActivation(rawValue: string(Key.pttActivation, Default.pttActivation)) ?? .hold }
        set { set(newValue.rawValue, Key.pttActivation) }
    }

    /// Prefer the built-in Mac microphone over Bluetooth mics. Keeps AirPods in
    /// the high-quality A2DP profile (using their mic forces the HFP call profile,
    /// which degrades output quality and shifts volume).
    @Setting(Key.preferBuiltInMic, Default.preferBuiltInMic) var preferBuiltInMic: Bool

    // MARK: - Meeting Mode

    /// Mic voice threshold in meeting mode, in dBFS (higher = less sensitive).
    @Setting(Key.meetingMicThreshold, Default.meetingMicThreshold) var meetingMicThreshold: Float

    /// System-audio voice threshold in meeting mode, in dBFS.
    @Setting(Key.systemAudioThreshold, Default.systemAudioThreshold) var systemAudioThreshold: Float

    /// Seconds of silence before a speech segment is flushed for transcription.
    @Setting(Key.silenceDebounce, Default.silenceDebounce) var silenceDebounce: TimeInterval

    /// Maximum segment length before a forced flush (Whisper's ~25s sweet spot).
    @Setting(Key.maxSegmentSeconds, Default.maxSegmentSeconds) var maxSegmentSeconds: TimeInterval

    /// Whether half-duplex echo suppression is active (built-in speaker mode).
    @Setting(Key.echoSuppressionEnabled, Default.echoSuppressionEnabled) var echoSuppressionEnabled: Bool

    /// How long the mic stays gated after speaker audio, in seconds.
    @Setting(Key.echoGateWindow, Default.echoGateWindow) var echoGateWindow: TimeInterval

    /// Label used for your own speech in the notes file.
    @Setting(Key.speakerLabelYou, Default.speakerLabelYou) var speakerLabelYou: String

    /// Label used for the other participants in the notes file.
    @Setting(Key.speakerLabelThem, Default.speakerLabelThem) var speakerLabelThem: String

    /// Folder where meeting notes markdown files are written.
    var notesFolder: URL {
        get {
            if let path = defaults.string(forKey: Key.notesFolderPath), !path.isEmpty {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
            return Default.notesFolder
        }
        set { set(newValue.path, Key.notesFolderPath) }
    }

    /// How the floating overlay behaves during meetings.
    var overlayMode: MeetingOverlayMode {
        get {
            guard let raw = defaults.string(forKey: Key.overlayMode),
                  let mode = MeetingOverlayMode(rawValue: raw) else { return Default.overlayMode }
            return mode
        }
        set { set(newValue.rawValue, Key.overlayMode) }
    }

    /// Seconds a live caption stays on screen after the last transcript line.
    @Setting(Key.captionLingerSeconds, Default.captionLingerSeconds) var captionLingerSeconds: Double

    /// How many times a failed meeting segment is retried before a failure marker.
    @Setting(Key.retryMaxAttempts, Default.retryMaxAttempts) var retryMaxAttempts: Int

    /// Seconds between retry passes for failed segments.
    @Setting(Key.retryIntervalSeconds, Default.retryIntervalSeconds) var retryIntervalSeconds: Double

    // MARK: - Meeting Intelligence

    /// Append an AI summary (TL;DR, decisions, action items) when a meeting ends.
    @Setting(Key.summariesEnabled, Default.summariesEnabled) var summariesEnabled: Bool

    /// Include an Action Items section in the end-of-meeting summary.
    @Setting(Key.actionItemsEnabled, Default.actionItemsEnabled) var actionItemsEnabled: Bool

    /// Append Decisions / Risks / Open Questions blocks to the meeting summary.
    @Setting(Key.structuredExtraction, Default.structuredExtraction) var structuredExtraction: Bool

    /// Extract meeting-type-specific key fields (deal stage, recommendation,
    /// budget, …) into the front-matter and a Key Details section.
    @Setting(Key.extractKeyFields, Default.extractKeyFields) var extractKeyFields: Bool

    /// Extract a list of questions that were raised but never clearly answered.
    @Setting(Key.extractUnanswered, Default.extractUnanswered) var extractUnanswered: Bool

    /// The keyword/competitor watchlist (one term per line). Meetings are scanned
    /// locally for these and matches are surfaced in a Mentions section + tags.
    var watchlistKeywords: String {
        get { string(Key.watchlistKeywords, "") }
        set { set(newValue, Key.watchlistKeywords) }
    }

    /// Parsed watchlist terms — non-empty, de-duplicated, order preserved.
    func watchlist() -> [String] {
        var seen = Set<String>(), out: [String] = []
        for raw in watchlistKeywords.components(separatedBy: CharacterSet(charactersIn: ",\n")) {
            let t = raw.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, seen.insert(t.lowercased()).inserted else { continue }
            out.append(t)
        }
        return out
    }

    /// Add one or more terms to the watchlist (comma/newline-separated input is
    /// split). Trims, de-duplicates case-insensitively, and preserves order.
    /// Returns the number actually added.
    @discardableResult
    func addWatchlistTerms(_ input: String) -> Int {
        var terms = watchlist()
        var seen = Set(terms.map { $0.lowercased() })
        var added = 0
        for raw in input.components(separatedBy: CharacterSet(charactersIn: ",\n")) {
            let t = raw.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, seen.insert(t.lowercased()).inserted else { continue }
            terms.append(t); added += 1
        }
        if added > 0 { watchlistKeywords = terms.joined(separator: "\n") }
        return added
    }

    /// Remove a single watchlist term (case-insensitive match).
    func removeWatchlistTerm(_ term: String) {
        let kept = watchlist().filter { $0.caseInsensitiveCompare(term) != .orderedSame }
        watchlistKeywords = kept.joined(separator: "\n")
    }

    /// Open notes in the OS default app (e.g. VS Code) instead of the in-app
    /// viewer. Applies wherever a note file is opened.
    @Setting(Key.openNotesExternally, Default.openNotesExternally) var openNotesExternally: Bool

    /// Append a topic-chapter jump-list (timestamped) to finished meeting notes.
    @Setting(Key.topicChapters, Default.topicChapters) var topicChapters: Bool

    /// Append a local talk-time / engagement readout (talk share, turns,
    /// questions, longest monologue, next-steps captured) to finished meeting
    /// notes. Computed on-device from the transcript — no AI, no network.
    @Setting(Key.talkTimeAnalytics, Default.talkTimeAnalytics) var talkTimeAnalytics: Bool

    /// Extract objections raised and competitor mentions (with context) into an
    /// "Objections & Competitors" section at the end of a meeting. One AI call.
    @Setting(Key.objectionIntel, Default.objectionIntel) var objectionIntel: Bool

    /// Let Ask plan multiple sub-searches and pull in Catalog facts (accounts,
    /// POC health, people) so it can answer across your whole knowledge base,
    /// not just one keyword search over meeting notes.
    @Setting(Key.agenticAsk, Default.agenticAsk) var agenticAsk: Bool

    /// Max retrieve→reason→retrieve hops for agentic Ask (1 = single round, no
    /// follow-up searches). Higher digs deeper but costs more fast-model calls.
    @Setting(Key.agenticAskMaxHops, Default.agenticAskMaxHops) var agenticAskMaxHops: Int

    /// Show a live rolling brief (TL;DR + open action items) during a meeting.
    /// Off by default — it makes periodic LLM calls while the meeting runs.
    @Setting(Key.liveAssistantEnabled, Default.liveAssistantEnabled) var liveAssistantEnabled: Bool

    /// Default for the per-meeting "Show prep card" switch — pops a panel of the
    /// linked org/opportunity's recent notes when a meeting starts.
    @Setting(Key.meetingPrepCard, Default.meetingPrepCard) var meetingPrepCard: Bool

    /// Show a notification when meeting notes are saved.
    @Setting(Key.notifyOnMeetingEnd, Default.notifyOnMeetingEnd) var notifyOnMeetingEnd: Bool

    /// Keep a compressed recording of each meeting under `<notes>/Audio/`, so a
    /// note whose transcription failed can be regenerated from the audio.
    @Setting(Key.retainMeetingAudio, Default.retainMeetingAudio) var retainMeetingAudio: Bool

    /// Prepend YAML front-matter (Obsidian/Notion friendly) to notes files.
    @Setting(Key.frontMatterEnabled, Default.frontMatterEnabled) var frontMatterEnabled: Bool

    /// How meeting notes files are organized under the notes folder.
    var notesOrganization: NotesOrganization {
        get {
            guard let raw = defaults.string(forKey: Key.notesOrganization),
                  let mode = NotesOrganization(rawValue: raw) else { return Default.notesOrganization }
            return mode
        }
        set { set(newValue.rawValue, Key.notesOrganization) }
    }

    /// How dictation files are organized under the dictations folder
    /// (independent of the meeting layout).
    var dictationOrganization: NotesOrganization {
        get {
            guard let raw = defaults.string(forKey: Key.dictationOrganization),
                  let mode = NotesOrganization(rawValue: raw) else { return Default.dictationOrganization }
            return mode
        }
        set { set(newValue.rawValue, Key.dictationOrganization) }
    }

    /// Largest audio file (MB) accepted by "Transcribe Audio File". Guards
    /// against oversized uploads; Groq caps request size regardless.
    var audioImportMaxMB: Int {
        get { let v = int(Key.audioImportMaxMB, Default.audioImportMaxMB); return v > 0 ? v : Default.audioImportMaxMB }
        set { set(max(1, newValue), Key.audioImportMaxMB) }
    }
    /// Seconds between meeting auto-detect polls (clamped 1–10).
    var meetingDetectInterval: Double {
        get { min(10, max(1, double(Key.meetingDetectInterval, Default.meetingDetectInterval))) }
        set { set(min(10, max(1, newValue)), Key.meetingDetectInterval) }
    }
    /// New transcript characters required before a live-brief refresh (clamped 100–2000).
    var liveBriefMinGrowth: Int {
        get { min(2000, max(100, int(Key.liveBriefMinGrowth, Default.liveBriefMinGrowth))) }
        set { set(min(2000, max(100, newValue)), Key.liveBriefMinGrowth) }
    }
    /// Timeout (seconds) for a single Groq transcription request (clamped 10–120).
    var transcriptionTimeout: Int {
        get { min(120, max(10, int(Key.transcriptionTimeout, Default.transcriptionTimeout))) }
        set { set(min(120, max(10, newValue)), Key.transcriptionTimeout) }
    }
    /// Network timeout for transcribing a whole imported audio file (longer than
    /// a live chunk, since a full recording can take a while to upload+process).
    var importTranscriptionTimeout: Int {
        get { min(300, max(30, int(Key.importTranscriptionTimeout, Default.importTranscriptionTimeout))) }
        set { set(min(300, max(30, newValue)), Key.importTranscriptionTimeout) }
    }
    /// Consecutive "quiet" detector polls before a meeting is considered ended
    /// (end latency ≈ this × meetingDetectInterval).
    var meetingEndQuietPolls: Int {
        get { min(5, max(1, int(Key.meetingEndQuietPolls, Default.meetingEndQuietPolls))) }
        set { set(min(5, max(1, newValue)), Key.meetingEndQuietPolls) }
    }
    /// Character budget of transcript fed into summary/extraction prompts —
    /// higher captures more of a long meeting at higher token cost.
    var summaryContextChars: Int {
        get { min(60000, max(8000, int(Key.summaryContextChars, Default.summaryContextChars))) }
        set { set(min(60000, max(8000, newValue)), Key.summaryContextChars) }
    }
    /// Push-to-talk tap-vs-hold threshold in seconds (clamped 0.15–1.0).
    var pttTapThreshold: Double {
        get { min(1.0, max(0.15, double(Key.pttTapThreshold, Default.pttTapThreshold))) }
        set { set(min(1.0, max(0.15, newValue)), Key.pttTapThreshold) }
    }

    /// Path of `url` relative to the notes folder (the leading folder + "/"
    /// dropped) — the form stored in the Catalog and in `gw_audio`. Returns the
    /// absolute path unchanged if it isn't under the notes folder.
    func relativePath(of url: URL) -> String {
        let root = notesFolder.path + "/"
        return url.path.hasPrefix(root) ? String(url.path.dropFirst(root.count)) : url.path
    }

    /// Apply the folder-organization setting to any base folder for a given
    /// date (e.g. base/2026/2026-07/03/). Folder names are POSIX-stable across
    /// user locales/calendars. Existing files are never moved.
    func organizedFolder(base: URL, using organization: NotesOrganization, for date: Date = Date()) -> URL {
        func stamp(_ format: String) -> String {
            DateDisplay.posixFormatter(format).string(from: date)
        }
        switch organization {
        case .flat:
            return base
        case .byYear:
            return base.appendingPathComponent(stamp("yyyy"), isDirectory: true)
        case .byMonth:
            return base.appendingPathComponent(stamp("yyyy"), isDirectory: true)
                       .appendingPathComponent(stamp("yyyy-MM"), isDirectory: true)
        case .byDay:
            return base.appendingPathComponent(stamp("yyyy"), isDirectory: true)
                       .appendingPathComponent(stamp("yyyy-MM"), isDirectory: true)
                       .appendingPathComponent(stamp("dd"), isDirectory: true)
        }
    }

    /// Folder a *new* meeting's notes file goes into, per the meeting
    /// organization setting (e.g. …/Notes/2026/2026-07/).
    func meetingDestinationFolder(for date: Date = Date()) -> URL {
        organizedFolder(base: notesFolder, using: notesOrganization, for: date)
    }

    /// Folder a *new* dictation file goes into, per the dictation organization
    /// setting (independent of meetings), under the dictations folder.
    func dictationDestinationFolder(for date: Date = Date()) -> URL {
        organizedFolder(base: dictationsFolder, using: dictationOrganization, for: date)
    }

    /// Folder a retained meeting recording goes into — `<notes>/Audio/` mirrored
    /// with the *same* dated organization as meeting notes (e.g. …/Audio/2026/2026-08/25/).
    func audioDestinationFolder(for date: Date = Date()) -> URL {
        organizedFolder(base: notesFolder.appendingPathComponent("Audio", isDirectory: true),
                        using: notesOrganization, for: date)
    }

    /// Experimental: label distinct remote speakers (Them / Them 2) by
    /// clustering voice fingerprints (pitch + timbre) per segment.
    @Setting(Key.diarizationEnabled, Default.diarizationEnabled) var diarizationEnabled: Bool

    /// Offer to start Meeting Mode when a conferencing app starts using the mic.
    @Setting(Key.meetingAutoDetect, Default.meetingAutoDetect) var meetingAutoDetect: Bool

    /// Interpret spoken commands in dictation ("new paragraph", "scratch that").
    @Setting(Key.voiceCommandsEnabled, Default.voiceCommandsEnabled) var voiceCommandsEnabled: Bool

    /// Editable voice-command rules, one per line ("spoken phrase → effect").
    /// Fed verbatim to the polishing model when voice commands are enabled.
    @Setting(Key.voiceCommandRules, Default.voiceCommandRules) var voiceCommandRules: String

    /// Transcribe long dictations in chunks while the key is still held.
    @Setting(Key.streamingDictation, Default.streamingDictation) var streamingDictation: Bool

    /// Chunk length for streaming dictation, in seconds.
    @Setting(Key.skipSilentDictation, Default.skipSilentDictation) var skipSilentDictation: Bool

    /// dBFS floor below which a dictation recording is treated as silence and
    /// never uploaded to Groq. More negative = more sensitive (uploads quieter
    /// audio); less negative = stricter (skips more).
    @Setting(Key.dictationSilenceThreshold, Default.dictationSilenceThreshold) var dictationSilenceThreshold: Float

    @Setting(Key.streamChunkSeconds, Default.streamChunkSeconds) var streamChunkSeconds: Double

    /// Voice-separation sensitivity for diarization — the distance threshold
    /// above which a voice is treated as a new speaker. Lower = splits more
    /// eagerly (risks over-splitting one voice); higher = merges similar voices.
    @Setting(Key.speakerSensitivity, Default.speakerSensitivity) var speakerSensitivity: Double

    /// How often (seconds) the live brief refreshes during a meeting — the
    /// main lever on its running cost.
    var liveBriefInterval: Int {
        get { max(10, int(Key.liveBriefInterval, Default.liveBriefInterval)) }
        set { set(newValue, Key.liveBriefInterval) }
    }

    /// Maximum entries kept in the AI summary/draft cache before the oldest are
    /// evicted.
    var aiCacheLimit: Int {
        get { max(50, int(Key.aiCacheLimit, Default.aiCacheLimit)) }
        set { set(newValue, Key.aiCacheLimit) }
    }

    /// Maximum distinct remote speakers the diarizer will label in a meeting.
    @Setting(Key.maxSpeakers, Default.maxSpeakers) var maxSpeakers: Int

    /// How many recent meetings the Catalog's Meaning search and Ask scan.
    @Setting(Key.searchDepth, Default.searchDepth) var searchDepth: Int

    /// Folder for dictated quick notes (⌃⌥J) — separate from meeting notes so
    /// the meeting history and Catalog stay meetings-only.
    /// Defaults to "Quick Notes" beside the meeting notes, inside the same base.
    var quickNotesFolder: URL {
        get {
            if let path = defaults.string(forKey: Key.quickNotesFolderPath), !path.isEmpty {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
            return notesFolder.appendingPathComponent("Quick Notes", isDirectory: true)
        }
        set { set(newValue.path, Key.quickNotesFolderPath) }
    }

    /// Archive each dictation to its own Markdown file (on by default; browse
    /// them from the menu → Dictations…).
    @Setting(Key.saveDictations, Default.saveDictations) var saveDictations: Bool

    /// Where dictation archive files live. Defaults to "Dictations" beside the
    /// meeting notes; kept separate so meeting history/search stay meetings-only.
    var dictationsFolder: URL {
        get {
            if let path = defaults.string(forKey: Key.dictationsFolderPath), !path.isEmpty {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
            return notesFolder.appendingPathComponent("Dictations", isDirectory: true)
        }
        set { set(newValue.path, Key.dictationsFolderPath) }
    }

    /// Show a notification (with the saved path, click to open) after a quick note.
    @Setting(Key.quickNoteNotify, Default.quickNoteNotify) var quickNoteNotify: Bool

    // MARK: - Meeting Templates

    /// The id of the template shaping the end-of-meeting summary. Either a
    /// built-in rawValue ("general") or a user template id ("user:UUID").
    /// Changeable per meeting from the menu; persists as the next default.
    /// Falls back to the built-in default if the stored id no longer exists
    /// (e.g. a user template was deleted).
    var selectedTemplateID: String {
        get {
            let stored = defaults.string(forKey: Key.meetingTemplate) ?? Default.meetingTemplate.rawValue
            return allTemplates.contains(where: { $0.id == stored }) ? stored : Default.meetingTemplate.rawValue
        }
        set { set(newValue, Key.meetingTemplate) }
    }

    /// The resolved template currently selected.
    var selectedTemplate: SummaryTemplate {
        template(withID: selectedTemplateID) ?? .builtIn(Default.meetingTemplate)
    }

    /// Every template — the built-in nine (with any section overrides applied)
    /// followed by the user's own, in creation order.
    var allTemplates: [SummaryTemplate] {
        MeetingTemplate.allCases.map { .builtIn($0) } + userTemplates.map { .user($0) }
    }

    /// Templates arranged into labeled sections for the pickers — built-ins by
    /// category (in `MeetingTemplate.Category` order), then the user's own
    /// under "Custom" when any exist.
    var groupedTemplates: [(title: String, templates: [SummaryTemplate])] {
        var groups: [(String, [SummaryTemplate])] = MeetingTemplate.Category.allCases.compactMap { cat in
            let items = MeetingTemplate.allCases.filter { $0.category == cat }.map { SummaryTemplate.builtIn($0) }
            return items.isEmpty ? nil : (cat.title, items)
        }
        let custom = userTemplates.map { SummaryTemplate.user($0) }
        if !custom.isEmpty { groups.append(("Custom", custom)) }
        return groups
    }

    /// Resolve a template by id.
    func template(withID id: String) -> SummaryTemplate? {
        allTemplates.first { $0.id == id }
    }

    // MARK: Built-in section overrides

    /// Per-built-in-template section overrides, keyed by rawValue. A value is
    /// the editable `Heading: instruction` text the user saved. Absent → the
    /// template uses its built-in defaults.
    private var templateOverrides: [String: String] {
        get {
            guard let data = defaults.data(forKey: Key.customTemplateSections),
                  let dict = try? JSONDecoder().decode([String: String].self, from: data)
            else { return [:] }
            return dict
        }
        set {
            let data = try? JSONEncoder().encode(newValue)
            set(data as Any, Key.customTemplateSections)
        }
    }

    /// The user's custom section text for a built-in template, or nil if none
    /// saved (meaning: use the built-in defaults).
    func customTemplateSections(for template: MeetingTemplate) -> String? {
        templateOverrides[template.rawValue]
    }

    /// Save a custom section list for a built-in template. Passing text equal
    /// to the defaults (or empty) clears the override so the template tracks
    /// any future default changes.
    func setCustomTemplateSections(_ text: String, for template: MeetingTemplate) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var dict = templateOverrides
        if trimmed.isEmpty || trimmed == template.defaultSectionsText {
            dict[template.rawValue] = nil
        } else {
            dict[template.rawValue] = text
        }
        templateOverrides = dict
    }

    /// Per-built-in-template follow-up guidance overrides, keyed by rawValue.
    /// Absent → the template uses its built-in follow-up guidance.
    private var templateFollowUpOverrides: [String: String] {
        get {
            guard let data = defaults.data(forKey: Key.customTemplateFollowUp),
                  let dict = try? JSONDecoder().decode([String: String].self, from: data)
            else { return [:] }
            return dict
        }
        set {
            let data = try? JSONEncoder().encode(newValue)
            set(data as Any, Key.customTemplateFollowUp)
        }
    }

    /// The user's custom follow-up guidance for a built-in template, or nil if
    /// none saved (meaning: use the built-in default).
    func customTemplateFollowUp(for template: MeetingTemplate) -> String? {
        templateFollowUpOverrides[template.rawValue]
    }

    /// Save custom follow-up guidance for a built-in template. Passing text
    /// equal to the default (or empty) clears the override.
    func setCustomTemplateFollowUp(_ text: String, for template: MeetingTemplate) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var dict = templateFollowUpOverrides
        if trimmed.isEmpty || trimmed == template.followUpGuidance {
            dict[template.rawValue] = nil
        } else {
            dict[template.rawValue] = text
        }
        templateFollowUpOverrides = dict
    }

    // MARK: Draft document templates (FollowUpKind guidance)

    /// Per-document-type drafting-guidance overrides, keyed by FollowUpKind
    /// rawValue. Absent → the kind uses its built-in guidance.
    private var draftGuidanceOverrides: [String: String] {
        get {
            guard let data = defaults.data(forKey: Key.draftGuidance),
                  let dict = try? JSONDecoder().decode([String: String].self, from: data)
            else { return [:] }
            return dict
        }
        set { set((try? JSONEncoder().encode(newValue)) as Any, Key.draftGuidance) }
    }

    /// The drafting guidance for a document type — the user's override when set,
    /// otherwise the built-in default.
    func draftGuidance(for kind: FollowUpKind) -> String {
        draftGuidanceOverrides[kind.rawValue] ?? kind.guidance
    }

    /// Whether a document type currently uses a custom (non-default) guidance.
    func hasCustomDraftGuidance(for kind: FollowUpKind) -> Bool {
        draftGuidanceOverrides[kind.rawValue] != nil
    }

    /// Save custom guidance for a document type. Text equal to the default (or
    /// empty) clears the override so it tracks future default changes.
    func setDraftGuidance(_ text: String, for kind: FollowUpKind) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var dict = draftGuidanceOverrides
        if trimmed.isEmpty || trimmed == kind.guidance {
            dict[kind.rawValue] = nil
        } else {
            dict[kind.rawValue] = text
        }
        draftGuidanceOverrides = dict
    }

    // MARK: User draft templates (custom output document types)

    /// The user's own draft document types, persisted as JSON in creation order.
    /// Each is just a name + guidance; drafting caches by guidance like the
    /// built-in `FollowUpKind` types.
    private(set) var userDraftTemplates: [UserDraftTemplate] {
        get {
            guard let data = defaults.data(forKey: Key.userDraftTemplates),
                  let list = try? JSONDecoder().decode([UserDraftTemplate].self, from: data)
            else { return [] }
            return list
        }
        set { set((try? JSONEncoder().encode(newValue)) as Any, Key.userDraftTemplates) }
    }

    /// Create a new custom draft template with starter guidance; returns its id.
    @discardableResult
    func addUserDraftTemplate(name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let template = UserDraftTemplate(
            id: "draft:\(UUID().uuidString)",
            name: trimmed.isEmpty ? "Untitled Document" : trimmed,
            guidance: "Describe the document to produce from the meeting notes — recipient, tone, sections, and format.")
        userDraftTemplates.append(template)
        return template.id
    }

    /// Update a custom draft template's name and/or guidance.
    func updateUserDraftTemplate(id: String, name: String? = nil, guidance: String? = nil) {
        var list = userDraftTemplates
        guard let i = list.firstIndex(where: { $0.id == id }) else { return }
        if let name = name {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            list[i].name = trimmed.isEmpty ? "Untitled Document" : trimmed
        }
        if let guidance = guidance { list[i].guidance = guidance }
        userDraftTemplates = list
    }

    /// Delete a custom draft template.
    func deleteUserDraftTemplate(id: String) {
        userDraftTemplates = userDraftTemplates.filter { $0.id != id }
    }

    /// Every draft document type — the built-in `FollowUpKind` set followed by
    /// the user's own — for the Draft… menu and the Draft Templates pane.
    var allDraftDocs: [DraftDoc] {
        FollowUpKind.allCases.map { .builtIn($0) } + userDraftTemplates.map { .user($0) }
    }

    /// Draft documents in labeled sections for the pickers/menus — built-ins by
    /// category, then the user's own under "Custom" when any exist.
    var groupedDraftDocs: [(title: String, docs: [DraftDoc])] {
        var groups: [(String, [DraftDoc])] = FollowUpKind.Category.allCases.compactMap { cat in
            let items = FollowUpKind.allCases.filter { $0.category == cat }.map { DraftDoc.builtIn($0) }
            return items.isEmpty ? nil : (cat.title, items)
        }
        let custom = userDraftTemplates.map { DraftDoc.user($0) }
        if !custom.isEmpty { groups.append(("Custom", custom)) }
        return groups
    }

    // MARK: User templates

    /// The user's own templates, persisted as JSON in creation order.
    private(set) var userTemplates: [UserTemplate] {
        get {
            guard let data = defaults.data(forKey: Key.userTemplates),
                  let list = try? JSONDecoder().decode([UserTemplate].self, from: data)
            else { return [] }
            return list
        }
        set {
            let data = try? JSONEncoder().encode(newValue)
            set(data as Any, Key.userTemplates)
        }
    }

    /// Create a new user template (with one starter section) and return its id.
    @discardableResult
    func addUserTemplate(name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let template = UserTemplate(
            id: "user:\(UUID().uuidString)",
            name: trimmed.isEmpty ? "Untitled" : trimmed,
            sections: "Summary: 2-3 sentences.\nKey Points: bullet list of the main points."
        )
        userTemplates.append(template)
        return template.id
    }

    /// Update a user template's name and/or sections.
    func updateUserTemplate(id: String, name: String? = nil, sections: String? = nil, followUp: String? = nil) {
        var list = userTemplates
        guard let i = list.firstIndex(where: { $0.id == id }) else { return }
        if let name = name {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            list[i].name = trimmed.isEmpty ? "Untitled" : trimmed
        }
        if let sections = sections { list[i].sections = sections }
        if let followUp = followUp { list[i].followUp = followUp }
        userTemplates = list
    }

    /// Delete a user template. If it was the selected default, selection
    /// falls back to the built-in default automatically (id no longer exists).
    func deleteUserTemplate(id: String) {
        userTemplates = userTemplates.filter { $0.id != id }
    }

    // MARK: - Template import / export

    /// How an incoming template bundle is applied — mirrors the Catalog's
    /// import semantics.
    enum TemplateImportMode { case merge, replace }

    /// Snapshot every piece of user-customized template data — custom meeting
    /// templates, custom draft document types, and any per-built-in overrides
    /// (sections / follow-up / draft guidance) — as portable JSON. Built-in
    /// definitions themselves are never exported (they ship with the app); only
    /// the user's additions and overrides travel.
    func exportTemplates() throws -> Data {
        let bundle = TemplateBundle(
            userTemplates: userTemplates,
            userDraftTemplates: userDraftTemplates,
            meetingSectionOverrides: templateOverrides,
            meetingFollowUpOverrides: templateFollowUpOverrides,
            draftGuidanceOverrides: draftGuidanceOverrides)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(bundle)
    }

    /// True if `data` decodes as a template bundle — guards against importing
    /// an unrelated JSON file.
    func isValidTemplateBundle(_ data: Data) -> Bool {
        (try? JSONDecoder().decode(TemplateBundle.self, from: data)) != nil
    }

    /// True when there is any custom template data to export (disables the
    /// Export control otherwise).
    var hasExportableTemplates: Bool {
        !userTemplates.isEmpty || !userDraftTemplates.isEmpty
            || !templateOverrides.isEmpty || !templateFollowUpOverrides.isEmpty
            || !draftGuidanceOverrides.isEmpty
    }

    /// Apply a template bundle. `.replace` swaps all custom template data for
    /// the bundle's; `.merge` upserts custom templates by id (incoming wins on
    /// clash) and layers the bundle's overrides on top of the current ones.
    /// Returns the number of custom templates + overrides applied.
    @discardableResult
    func importTemplates(_ data: Data, mode: TemplateImportMode) throws -> Int {
        let bundle = try JSONDecoder().decode(TemplateBundle.self, from: data)
        switch mode {
        case .replace:
            userTemplates = bundle.userTemplates
            userDraftTemplates = bundle.userDraftTemplates
            templateOverrides = bundle.meetingSectionOverrides
            templateFollowUpOverrides = bundle.meetingFollowUpOverrides
            draftGuidanceOverrides = bundle.draftGuidanceOverrides
        case .merge:
            userTemplates = Self.upsert(userTemplates, bundle.userTemplates)
            userDraftTemplates = Self.upsert(userDraftTemplates, bundle.userDraftTemplates)
            templateOverrides.merge(bundle.meetingSectionOverrides) { _, new in new }
            templateFollowUpOverrides.merge(bundle.meetingFollowUpOverrides) { _, new in new }
            draftGuidanceOverrides.merge(bundle.draftGuidanceOverrides) { _, new in new }
        }
        // Selection may reference a template that was replaced away — the
        // selectedTemplateID getter self-heals, so nothing to do here.
        return bundle.userTemplates.count + bundle.userDraftTemplates.count
            + bundle.meetingSectionOverrides.count + bundle.meetingFollowUpOverrides.count
            + bundle.draftGuidanceOverrides.count
    }

    /// Upsert `incoming` into `base` by id, preserving base order and appending
    /// genuinely new items (incoming values win on id clash).
    private static func upsert<T: Identifiable>(_ base: [T], _ incoming: [T]) -> [T] where T.ID == String {
        var result = base
        for item in incoming {
            if let i = result.firstIndex(where: { $0.id == item.id }) {
                result[i] = item
            } else {
                result.append(item)
            }
        }
        return result
    }

    // MARK: - Dictation Writing Styles

    /// Every dictation style — the six built-in categories (with any
    /// instruction overrides applied) followed by the user's own.
    var allDictationStyles: [DictationStyle] {
        AppCategory.allCases.map { .builtIn($0) } + userDictationStyles.map { .user($0) }
    }

    /// Resolve a style by id.
    func dictationStyle(withID id: String) -> DictationStyle? {
        allDictationStyles.first { $0.id == id }
    }

    /// The global default style used when the app being dictated into isn't
    /// auto-recognized and has no per-app override. Persists by id (a category
    /// rawValue or "user:UUID"); self-heals to General if the id is gone.
    var defaultDictationStyleID: String {
        get {
            let stored = defaults.string(forKey: Key.defaultDictationStyle) ?? AppCategory.general.rawValue
            return allDictationStyles.contains(where: { $0.id == stored }) ? stored : AppCategory.general.rawValue
        }
        set { set(newValue, Key.defaultDictationStyle) }
    }

    var defaultDictationStyle: DictationStyle {
        dictationStyle(withID: defaultDictationStyleID) ?? .builtIn(.general)
    }

    /// Whether to read the active browser tab's URL (via Automation) so a
    /// domain rule / the log can distinguish sites inside a browser.
    @Setting(Key.browserTabDetection, Default.browserTabDetection) var browserTabDetection: Bool

    /// Newline rules mapping a host substring to a style key, e.g.
    /// "mail.google.com: email". Applied when dictating in a browser.
    @Setting(Key.domainStyleRules, Default.domainStyleRules) var domainStyleRules: String

    /// Parsed `host: style` rules, in order, skipping blank/malformed lines.
    /// The structured browser-tab editor reads and writes through this.
    var domainStyleList: [(host: String, style: String)] {
        domainStyleRules.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].isEmpty else { return nil }
            return (parts[0], parts[1])
        }
    }

    /// The selectable style keys for domain/app rules — the built-in categories
    /// followed by the user's own styles (by name). Values are the keys stored
    /// in the rules; labels are what the picker shows.
    var dictationStyleKeys: [(key: String, label: String)] {
        AppCategory.allCases.map { ($0.rawValue, $0.displayName) }
            + userDictationStyles.map { ($0.name, $0.name) }
    }

    /// Resolve a style key ("email", "code", or a custom style's name) to a
    /// concrete style: a built-in category first, then a user style by name.
    func dictationStyle(forKey key: String) -> DictationStyle? {
        let k = key.trimmingCharacters(in: .whitespaces).lowercased()
        guard !k.isEmpty else { return nil }
        if let category = AppCategory(rawValue: k) { return .builtIn(category) }
        if let user = userDictationStyles.first(where: { $0.name.lowercased() == k }) {
            return .user(user)
        }
        return nil
    }

    /// The style for a browser host from the domain rules, if any rule's host
    /// substring appears in `host`.
    func domainStyle(forHost host: String) -> DictationStyle? {
        let lowerHost = host.lowercased()
        for line in domainStyleRules.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].isEmpty else { continue }
            if lowerHost.contains(parts[0].lowercased()), let style = dictationStyle(forKey: parts[1]) {
                return style
            }
        }
        return nil
    }

    /// Choose the style for a given dictation context. Browser tab domain rule
    /// wins (most specific); then a per-app override; then a recognized
    /// (non-general) app category; otherwise the global default style.
    func resolvedDictationStyle(for context: AppContext) -> DictationStyle {
        if context.category == .browser, let host = context.host,
           let style = domainStyle(forHost: host) {
            return style
        }
        if let style = appProfileStyle(forBundleID: context.bundleID) {
            return style
        }
        if context.category != .general {
            return .builtIn(context.category)
        }
        return defaultDictationStyle
    }

    // MARK: Built-in style overrides

    /// Per-built-in-style instruction overrides, keyed by category rawValue.
    private var styleOverrides: [String: String] {
        get {
            guard let data = defaults.data(forKey: Key.dictationStyleOverrides),
                  let dict = try? JSONDecoder().decode([String: String].self, from: data)
            else { return [:] }
            return dict
        }
        set {
            let data = try? JSONEncoder().encode(newValue)
            set(data as Any, Key.dictationStyleOverrides)
        }
    }

    /// The user's custom instruction for a built-in style, or nil if unset.
    func dictationStyleOverride(for category: AppCategory) -> String? {
        styleOverrides[category.rawValue]
    }

    /// Save a custom instruction for a built-in style. Empty text (or text
    /// equal to the default) clears the override.
    func setDictationStyleOverride(_ text: String, for category: AppCategory) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var dict = styleOverrides
        if trimmed.isEmpty || trimmed == category.defaultInstruction {
            dict[category.rawValue] = nil
        } else {
            dict[category.rawValue] = text
        }
        styleOverrides = dict
    }

    // MARK: User styles

    /// The user's own dictation styles, persisted as JSON in creation order.
    private(set) var userDictationStyles: [UserStyle] {
        get {
            guard let data = defaults.data(forKey: Key.userDictationStyles),
                  let list = try? JSONDecoder().decode([UserStyle].self, from: data)
            else { return [] }
            return list
        }
        set {
            let data = try? JSONEncoder().encode(newValue)
            set(data as Any, Key.userDictationStyles)
        }
    }

    @discardableResult
    func addUserDictationStyle(name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let style = UserStyle(
            id: "user:\(UUID().uuidString)",
            name: trimmed.isEmpty ? "Untitled" : trimmed,
            instruction: "Clean up the text in a clear, natural style."
        )
        userDictationStyles.append(style)
        return style.id
    }

    func updateUserDictationStyle(id: String, name: String? = nil, instruction: String? = nil) {
        var list = userDictationStyles
        guard let i = list.firstIndex(where: { $0.id == id }) else { return }
        if let name = name {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            list[i].name = trimmed.isEmpty ? "Untitled" : trimmed
        }
        if let instruction = instruction { list[i].instruction = instruction }
        userDictationStyles = list
    }

    func deleteUserDictationStyle(id: String) {
        userDictationStyles = userDictationStyles.filter { $0.id != id }
    }

    // MARK: - Privacy

    /// Never contact the network: transcribe on-device and skip all LLM steps
    /// (polishing, summaries, auto-tagging, follow-up drafts).
    @Setting(Key.localOnlyMode, Default.localOnlyMode) var localOnlyMode: Bool

    /// Scrub sensitive tokens from transcribed text before it is used.
    @Setting(Key.redactionEnabled, Default.redactionEnabled) var redactionEnabled: Bool
    @Setting(Key.redactEmails, Default.redactEmails) var redactEmails: Bool
    @Setting(Key.redactPhones, Default.redactPhones) var redactPhones: Bool
    @Setting(Key.redactNumbers, Default.redactNumbers) var redactNumbers: Bool

    // MARK: - Cost Estimate Pricing (USD, editable — provider prices drift)

    @Setting(Key.priceAudioPerHour, Default.priceAudioPerHour) var priceAudioPerHour: Double
    @Setting(Key.priceInputPerMTok, Default.priceInputPerMTok) var priceInputPerMTok: Double
    @Setting(Key.priceOutputPerMTok, Default.priceOutputPerMTok) var priceOutputPerMTok: Double

    /// Soft monthly spend cap in USD. 0 = no budget. When this month's estimated
    /// Groq spend crosses it, GhostWriter warns (banner + one notification).
    @Setting(Key.monthlyBudgetUSD, Default.monthlyBudgetUSD) var monthlyBudgetUSD: Double

    // MARK: - Integrations (event hooks)

    /// POST a JSON payload to a user-configured URL when a meeting finishes.
    /// Off by default; suppressed entirely in Local-only mode.
    @Setting(Key.webhookEnabled, Default.webhookEnabled) var webhookEnabled: Bool

    /// The destination URL for the outgoing webhook (must be https for it to fire).
    @Setting(Key.webhookURL, Default.webhookURL) var webhookURL: String

    /// Run a user-configured local script when a meeting finishes, receiving the
    /// event payload as JSON on stdin. Off by default.
    @Setting(Key.scriptHookEnabled, Default.scriptHookEnabled) var scriptHookEnabled: Bool

    /// Absolute path to the executable script run on meeting finish.
    @Setting(Key.scriptHookPath, Default.scriptHookPath) var scriptHookPath: String

    // MARK: - Follow-Up Packet
    // Which sections the one-click Follow-Up Packet assembles from a meeting.

    /// The curated default packet: a follow-up email, an updated POC plan, and
    /// the action items — in that order.
    static let defaultPacketSections = ["followUpEmail", "pocPlan", "actionItemList"]

    /// Ordered packet section identifiers — each is a `FollowUpKind` rawValue or
    /// a user draft-template id ("user:UUID"). Order is the order they appear in
    /// the composed document. Migrates once from the legacy include-toggles the
    /// first time it's read, so upgrading users keep their choices.
    var packetSectionIDs: [String] {
        get {
            if let raw = defaults.string(forKey: Key.packetSections) {
                return raw.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
            var ids: [String] = []
            if bool(Key.packetIncludeEmail, Default.packetIncludeEmail) { ids.append("followUpEmail") }
            if bool(Key.packetIncludePOC, Default.packetIncludePOC) { ids.append("pocPlan") }
            if bool(Key.packetIncludeActions, Default.packetIncludeActions) { ids.append("actionItemList") }
            return ids
        }
        set { set(newValue.joined(separator: ","), Key.packetSections) }
    }

    // Note: the legacy `packetInclude{Email,POC,Actions}` keys/defaults are read
    // directly (via `bool(Key…, Default…)`) inside the `packetSectionIDs` getter
    // to migrate a pre-0.31 install's choices, and are still cleared by
    // `resetToDefaults()` through `Key.all`. No dedicated accessors are needed.

    /// Ask for confirmation before the packet runs its cloud AI calls. On by
    /// default (the packet fires several requests at once); the "Don't ask
    /// again" choice in the dialog clears this.
    @Setting(Key.packetConfirmBeforeRun, Default.packetConfirmBeforeRun) var packetConfirmBeforeRun: Bool

    // MARK: - Transcription Quality

    /// Fall back to Apple's on-device speech recognition when Groq is unreachable.
    @Setting(Key.offlineFallback, Default.offlineFallback) var offlineFallback: Bool

    /// Prefer Apple's on-device model for summaries & drafts over Groq, while
    /// still using Groq for transcription. Falls back to Groq if the on-device
    /// model isn't available on this Mac.
    @Setting(Key.preferOnDeviceAI, Default.preferOnDeviceAI) var preferOnDeviceAI: Bool

    /// Proactive digest — a scheduled rollup of meetings, open action items, and
    /// quiet relationships.
    @Setting(Key.digestEnabled, Default.digestEnabled) var digestEnabled: Bool
    @Setting(Key.digestFrequency, Default.digestFrequency) var digestFrequency: String
    @Setting(Key.digestHour, Default.digestHour) var digestHour: Int
    @Setting(Key.digestWeekday, Default.digestWeekday) var digestWeekday: Int
    @Setting(Key.staleRelationshipDays, Default.staleRelationshipDays) var staleRelationshipDays: Int
    /// "yyyy-MM-dd" of the last generated digest (empty = never). Not user-facing.
    var lastDigestDay: String {
        get { string(Key.lastDigestDay, "") }
        set { set(newValue, Key.lastDigestDay) }
    }

    // MARK: - Automatic Backups

    /// Write a dated `.zip` snapshot of all GhostWriter data once per day,
    /// keeping only the most recent few (see `autoBackupRetentionDays`). The
    /// backup is opportunistic — it runs the first time the app is awake on a
    /// new day, not at a fixed clock time — so a Mac that was asleep at midnight
    /// still gets backed up.
    @Setting(Key.autoBackupEnabled, Default.autoBackupEnabled) var autoBackupEnabled: Bool

    /// How many most-recent daily auto-backup archives to keep; older ones are
    /// pruned after each successful backup. Clamped to at least 1.
    var autoBackupRetentionDays: Int {
        get { max(1, int(Key.autoBackupRetentionDays, Default.autoBackupRetentionDays)) }
        set { set(max(1, newValue), Key.autoBackupRetentionDays) }
    }

    /// Folder the automatic daily archives are written into. Defaults to a
    /// `Backups` folder in Application Support, which the OS never purges.
    var autoBackupFolder: URL {
        get {
            if let path = defaults.string(forKey: Key.autoBackupFolderPath), !path.isEmpty {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
            return AppPaths.support().appendingPathComponent("Backups", isDirectory: true)
        }
        set { set(newValue.path, Key.autoBackupFolderPath) }
    }

    /// When the last automatic backup completed (nil = never). The "backed up
    /// or not today" marker surfaced in Settings is derived from this.
    var lastAutomaticBackupAt: Date? {
        get {
            let t = double(Key.lastAutoBackupAt, 0)
            return t > 0 ? Date(timeIntervalSince1970: t) : nil
        }
        set { set(newValue?.timeIntervalSince1970 ?? 0, Key.lastAutoBackupAt) }
    }

    /// Whether an automatic backup has already been written today — the
    /// scheduler's due-check and the Settings marker both read this.
    var hasBackedUpToday: Bool {
        guard let last = lastAutomaticBackupAt else { return false }
        return Calendar.current.isDateInToday(last)
    }

    /// Have the summarizer extract topic tags into the notes front-matter.
    @Setting(Key.autoTagging, Default.autoTagging) var autoTagging: Bool

    /// Post a notification when something fails (also logged in Diagnostics).
    @Setting(Key.errorNotifications, Default.errorNotifications) var errorNotifications: Bool

    /// DateFormatter pattern for dates shown in the menu and Catalog.
    @Setting(Key.uiDateFormat, Default.uiDateFormat) var uiDateFormat: String

    /// Paper size for exported PDFs (notes, reports, POCs): "letter" or "a4".
    @Setting(Key.pdfPaperSize, Default.pdfPaperSize) var pdfPaperSize: String
    /// Point dimensions (72 dpi) for the chosen paper size — US Letter or A4.
    var pdfPageSize: CGSize {
        pdfPaperSize == "a4" ? CGSize(width: 595, height: 842) : CGSize(width: 612, height: 792)
    }

    /// ISO 639-1 language hint for Whisper (e.g. "en", "de", "ta").
    @Setting(Key.transcriptionLanguage, Default.transcriptionLanguage) var transcriptionLanguage: String

    /// Keep an in-memory list of recent dictations (for recall / ⌃⌥V).
    @Setting(Key.dictationHistoryOn, Default.dictationHistoryOn) var dictationHistoryEnabled: Bool

    /// How many recent dictations to keep.
    @Setting(Key.dictationHistoryLimit, Default.dictationHistoryLimit) var dictationHistoryLimit: Int

    /// Domain terms fed to Whisper as a prompt hint (names, acronyms, jargon).
    /// Comma- or newline-separated.
    var vocabulary: String {
        get { string(Key.vocabulary, "") }
        set { set(newValue, Key.vocabulary) }
    }

    /// Post-transcription find→replace rules, one per line: `wrong => right`.
    var replacements: String {
        get { string(Key.replacements, "") }
        set { set(newValue, Key.replacements) }
    }

    /// Per-app polishing style overrides, one per line: `bundle.id: style`
    /// where style is a built-in category (messaging|email|code|browser|notes|
    /// general) or a custom style's name.
    var appProfiles: String {
        get { string(Key.appProfiles, "") }
        set { set(newValue, Key.appProfiles) }
    }

    /// Parsed `bundle.id: style` overrides, in order, skipping blank/malformed
    /// lines. The structured per-app editor reads and writes through this.
    var appProfileList: [(bundleID: String, style: String)] {
        appProfiles.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].isEmpty else { return nil }
            return (parts[0], parts[1])
        }
    }

    /// Extra apps (bundle ids, one per line) where dictated text must be pasted
    /// via ⌘V rather than set through the Accessibility API. Chromium-based and
    /// Electron apps report a successful AX set but insert nothing, so text
    /// silently drops; forcing the clipboard path fixes them. Ships empty — the
    /// common offenders are covered by `TextInjector`'s built-in list.
    var pasteOnlyApps: String {
        get { string(Key.pasteOnlyApps, "") }
        set { set(newValue, Key.pasteOnlyApps) }
    }

    /// Parsed, lowercased set of user-declared paste-only bundle ids.
    var pasteOnlyBundleIDs: Set<String> {
        Set(pasteOnlyApps.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty })
    }

    // MARK: - Derived helpers

    /// Parsed replacement rules in declaration order.
    var replacementRules: [(find: String, replace: String)] {
        replacements.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.components(separatedBy: "=>")
            guard parts.count == 2 else { return nil }
            let find = parts[0].trimmingCharacters(in: .whitespaces)
            let replace = parts[1].trimmingCharacters(in: .whitespaces)
            guard !find.isEmpty else { return nil }
            return (find, replace)
        }
    }

    /// Applies the user's replacement rules (case-insensitive find).
    func applyReplacements(to text: String) -> String {
        var result = text
        for rule in replacementRules {
            result = result.replacingOccurrences(
                of: rule.find, with: rule.replace,
                options: [.caseInsensitive])
        }
        return result
    }


    /// The glossary prompt hint: the user's own vocabulary, deduplicated
    /// case-insensitively and capped to Whisper's prompt budget. Empty when
    /// there are no terms at all.
    func vocabularyHint() -> String {
        let raw = vocabulary.components(separatedBy: CharacterSet(charactersIn: ",\n"))
        var seen = Set<String>()
        var terms: [String] = []
        for candidate in raw {
            let term = candidate.trimmingCharacters(in: .whitespaces)
            guard !term.isEmpty, seen.insert(term.lowercased()).inserted else { continue }
            terms.append(term)
        }
        guard !terms.isEmpty else { return "" }
        return String(("Glossary: " + terms.joined(separator: ", ")).prefix(400))
    }

    /// The style for a bundle id from the per-app overrides, resolving both
    /// built-in categories and custom user styles (matched by name), or nil if
    /// no rule matches. First matching rule wins.
    func appProfileStyle(forBundleID bundleID: String) -> DictationStyle? {
        let lower = bundleID.lowercased()
        for rule in appProfileList where rule.bundleID.lowercased() == lower {
            if let style = dictationStyle(forKey: rule.style) { return style }
        }
        return nil
    }

    // MARK: - Reset

    /// Removes all stored values, reverting every setting to its default.
    func resetToDefaults() {
        objectWillChange.send()
        Key.all.forEach { defaults.removeObject(forKey: $0) }
    }

    // MARK: - Typed helpers (fall back to default when key is unset)

    private func set(_ value: Any, _ key: String) {
        objectWillChange.send()
        defaults.set(value, forKey: key)
    }
    private func double(_ key: String, _ fallback: Double) -> Double {
        defaults.object(forKey: key) == nil ? fallback : defaults.double(forKey: key)
    }
    private func int(_ key: String, _ fallback: Int) -> Int {
        defaults.object(forKey: key) == nil ? fallback : defaults.integer(forKey: key)
    }
    private func bool(_ key: String, _ fallback: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
    }
    private func string(_ key: String, _ fallback: String) -> String {
        defaults.string(forKey: key) ?? fallback
    }
}
