import Foundation
import Combine

// MARK: - App Settings
//
// UserDefaults-backed settings store. Every value has a default matching the
// previously hard-coded behavior, so a fresh install behaves identically.
// ObservableObject so SwiftUI views refresh when any value changes (incl. reset).

final class AppSettings: ObservableObject {

    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    private init() {}

    // MARK: - Keys

    private enum Key {
        static let transcriptionModel     = "api.transcriptionModel"
        static let polishingModel         = "api.polishingModel"
        static let fastModel              = "api.fastModel"
        static let pttKeyCode             = "dictation.pttKeyCode"
        static let pttActivation          = "dictation.pttActivation"
        static let preferBuiltInMic       = "audio.preferBuiltInMic"
        static let meetingMicThreshold    = "meeting.micThresholdDBFS"
        static let systemAudioThreshold   = "meeting.systemAudioThresholdDBFS"
        static let silenceDebounce        = "meeting.silenceDebounceSeconds"
        static let maxSegmentSeconds      = "meeting.maxSegmentSeconds"
        static let echoGateWindow         = "meeting.echoGateWindowSeconds"
        static let echoSuppressionEnabled = "meeting.echoSuppressionEnabled"
        static let speakerLabelYou        = "meeting.speakerLabelYou"
        static let speakerLabelThem       = "meeting.speakerLabelThem"
        static let notesFolderPath        = "meeting.notesFolderPath"
        static let overlayMode            = "meeting.overlayMode"
        static let summariesEnabled       = "meeting.summariesEnabled"
        static let actionItemsEnabled     = "meeting.actionItemsEnabled"
        static let structuredExtraction   = "meeting.structuredExtraction"
        static let extractKeyFields       = "meeting.extractKeyFields"
        static let extractUnanswered      = "meeting.extractUnanswered"
        static let watchlistKeywords      = "meeting.watchlistKeywords"
        static let draftGuidance          = "meeting.draftGuidance"
        static let userDraftTemplates     = "meeting.userDraftTemplates"
        static let openNotesExternally    = "notes.openExternally"
        static let topicChapters          = "meeting.topicChapters"
        static let liveAssistantEnabled   = "meeting.liveAssistantEnabled"
        static let meetingPrepCard        = "meeting.prepCard"
        static let notifyOnMeetingEnd     = "meeting.notifyOnMeetingEnd"
        static let frontMatterEnabled     = "meeting.frontMatterEnabled"
        static let diarizationEnabled     = "meeting.diarizationEnabled"
        static let offlineFallback        = "transcription.offlineFallback"
        static let preferOnDeviceAI       = "ai.preferOnDevice"
        static let digestEnabled          = "digest.enabled"
        static let digestFrequency        = "digest.frequency"   // "daily" | "weekly" | "monthly" | "yearly"
        static let digestHour             = "digest.hour"        // 0–23
        static let digestWeekday          = "digest.weekday"     // 1=Sun … 7=Sat
        static let staleRelationshipDays  = "digest.staleDays"
        static let lastDigestDay          = "digest.lastDay"     // "yyyy-MM-dd" of last run
        static let transcriptionLanguage  = "transcription.language"
        static let vocabulary             = "transcription.vocabulary"
        static let replacements           = "transcription.replacements"
        static let appProfiles            = "polishing.appProfiles"
        static let dictationHistoryOn     = "dictation.historyEnabled"
        static let dictationHistoryLimit  = "dictation.historyLimit"
        static let captionLingerSeconds   = "meeting.captionLingerSeconds"
        static let retryMaxAttempts       = "meeting.retryMaxAttempts"
        static let retryIntervalSeconds   = "meeting.retryIntervalSeconds"
        static let notesOrganization      = "meeting.notesOrganization"
        static let meetingAutoDetect      = "meeting.autoDetect"
        static let voiceCommandsEnabled   = "dictation.voiceCommands"
        static let voiceCommandRules      = "dictation.voiceCommandRules"
        static let streamingDictation     = "dictation.streaming"
        static let streamChunkSeconds     = "dictation.streamChunkSeconds"
        static let skipSilentDictation    = "dictation.skipSilent"
        static let dictationSilenceThreshold = "dictation.silenceThreshold"
        static let maxSpeakers            = "meeting.maxSpeakers"
        static let speakerSensitivity     = "meeting.speakerSensitivity"
        static let liveBriefInterval      = "meeting.liveBriefInterval"
        static let aiCacheLimit           = "ai.cacheLimit"
        static let searchDepth            = "assistant.searchDepth"
        static let meetingTemplate        = "meeting.template"
        static let customTemplateSections = "meeting.customTemplateSections"
        static let customTemplateFollowUp = "meeting.customTemplateFollowUp"
        static let userTemplates          = "meeting.userTemplates"
        static let dictationStyleOverrides = "dictation.styleOverrides"
        static let userDictationStyles     = "dictation.userStyles"
        static let defaultDictationStyle   = "dictation.defaultStyle"
        static let quickNotesFolderPath   = "quicknotes.folderPath"
        static let quickNoteNotify        = "quicknotes.notifyOnSave"
        static let localOnlyMode          = "privacy.localOnly"
        static let redactionEnabled       = "privacy.redactionEnabled"
        static let redactEmails           = "privacy.redactEmails"
        static let redactPhones           = "privacy.redactPhones"
        static let redactNumbers          = "privacy.redactNumbers"
        static let autoTagging            = "meeting.autoTagging"
        static let errorNotifications     = "diagnostics.errorNotifications"
        static let uiDateFormat           = "ui.dateFormat"
        static let pdfPaperSize           = "export.pdfPaperSize"
        static let browserTabDetection    = "dictation.browserTabDetection"
        static let domainStyleRules       = "dictation.domainStyleRules"
        static let saveDictations         = "dictation.saveToFiles"
        static let dictationsFolderPath   = "dictation.folderPath"
        static let dictationOrganization  = "dictation.organization"
        static let audioImportMaxMB       = "import.maxMB"
        static let meetingDetectInterval  = "meeting.detectInterval"
        static let liveBriefMinGrowth     = "meeting.liveBriefMinGrowth"
        static let transcriptionTimeout   = "transcription.requestTimeout"
        static let importTranscriptionTimeout = "transcription.importTimeout"
        static let meetingEndQuietPolls   = "meeting.endQuietPolls"
        static let summaryContextChars    = "ai.summaryContextChars"
        static let pttTapThreshold        = "dictation.pttTapThreshold"
        static let priceAudioPerHour      = "cost.audioPerHour"
        static let priceInputPerMTok      = "cost.inputPerMTok"
        static let priceOutputPerMTok     = "cost.outputPerMTok"
        static let monthlyBudgetUSD       = "cost.monthlyBudgetUSD"
        static let webhookEnabled         = "integrations.webhookEnabled"
        static let webhookURL             = "integrations.webhookURL"
        static let scriptHookEnabled      = "integrations.scriptHookEnabled"
        static let scriptHookPath         = "integrations.scriptHookPath"
        static let packetIncludeEmail     = "packet.includeEmail"
        static let packetIncludePOC       = "packet.includePOC"
        static let packetIncludeActions   = "packet.includeActions"   // legacy — migrated into packetSections
        static let packetConfirmBeforeRun = "packet.confirmBeforeRun"
        static let packetSections         = "packet.sections"

        static let all = [transcriptionModel, polishingModel, fastModel, pttKeyCode,
                          pttActivation,
                          preferBuiltInMic,
                          meetingMicThreshold, systemAudioThreshold,
                          silenceDebounce, maxSegmentSeconds, echoGateWindow,
                          echoSuppressionEnabled, speakerLabelYou, speakerLabelThem,
                          notesFolderPath, overlayMode,
                          summariesEnabled, actionItemsEnabled,
                          structuredExtraction, extractKeyFields, extractUnanswered, watchlistKeywords, draftGuidance, userDraftTemplates, openNotesExternally, topicChapters, liveAssistantEnabled, meetingPrepCard,
                          notifyOnMeetingEnd, frontMatterEnabled,
                          diarizationEnabled, offlineFallback, preferOnDeviceAI, transcriptionLanguage,
                          digestEnabled, digestFrequency, digestHour, digestWeekday, staleRelationshipDays, lastDigestDay,
                          vocabulary, replacements, appProfiles,
                          dictationHistoryOn, dictationHistoryLimit,
                          captionLingerSeconds, retryMaxAttempts, retryIntervalSeconds,
                          notesOrganization, meetingAutoDetect,
                          voiceCommandsEnabled, voiceCommandRules, streamingDictation,
                          streamChunkSeconds, skipSilentDictation, dictationSilenceThreshold,
                          maxSpeakers, speakerSensitivity,
                          liveBriefInterval, aiCacheLimit,
                          searchDepth, meetingTemplate,
                          customTemplateSections, customTemplateFollowUp, userTemplates,
                          dictationStyleOverrides, userDictationStyles, defaultDictationStyle,
                          quickNotesFolderPath, quickNoteNotify,
                          localOnlyMode, redactionEnabled, redactEmails, redactPhones, redactNumbers,
                          autoTagging, errorNotifications, uiDateFormat, pdfPaperSize,
                          browserTabDetection, domainStyleRules,
                          saveDictations, dictationsFolderPath, dictationOrganization, audioImportMaxMB,
                          meetingDetectInterval, liveBriefMinGrowth, transcriptionTimeout,
                          importTranscriptionTimeout, meetingEndQuietPolls, summaryContextChars, pttTapThreshold,
                          priceAudioPerHour, priceInputPerMTok, priceOutputPerMTok,
                          monthlyBudgetUSD,
                          webhookEnabled, webhookURL, scriptHookEnabled, scriptHookPath,
                          packetIncludeEmail, packetIncludePOC, packetIncludeActions,
                          packetConfirmBeforeRun, packetSections]
    }

    // MARK: - Defaults (previous hard-coded values)

    enum Default {
        static let transcriptionModel              = "whisper-large-v3"
        static let polishingModel                  = "meta-llama/llama-4-scout-17b-16e-instruct"  // 500K TPD / 30K TPM — avoids the 70B daily cap
        static let fastModel                       = "llama-3.1-8b-instant"
        static let pttKeyCode: Int                 = 61     // Right Option
        static let pttActivation                   = "toggle" // hold | tapLock | toggle
        static let preferBuiltInMic                = false  // use the system default input
        static let meetingMicThreshold: Float      = -40.0
        static let systemAudioThreshold: Float     = -50.0
        static let silenceDebounce: TimeInterval   = 1.5
        static let maxSegmentSeconds: TimeInterval = 25.0
        static let echoGateWindow: TimeInterval    = 0.4
        static let echoSuppressionEnabled          = true
        static let speakerLabelYou                 = "You"
        static let speakerLabelThem                = "Them"
        static let overlayMode                     = MeetingOverlayMode.minimal
        static let summariesEnabled                = true
        static let actionItemsEnabled              = true
        static let structuredExtraction            = true
        static let extractKeyFields                = true
        static let extractUnanswered               = true
        static let openNotesExternally             = false
        static let topicChapters                   = true
        static let liveAssistantEnabled            = true
        static let meetingPrepCard                 = true
        static let notifyOnMeetingEnd              = true
        static let frontMatterEnabled              = true
        static let diarizationEnabled              = true
        static let offlineFallback                 = true
        static let preferOnDeviceAI                = false
        static let digestEnabled                   = false
        static let digestFrequency                 = "daily"
        static let digestHour                      = 9
        static let digestWeekday                   = 2       // Monday
        static let staleRelationshipDays           = 30
        static let transcriptionLanguage           = "en"
        static let dictationHistoryOn              = true
        static let dictationHistoryLimit           = 20
        static let captionLingerSeconds: Double    = 6.0
        static let retryMaxAttempts                = 3
        static let retryIntervalSeconds: Double    = 20.0
        static let notesOrganization               = NotesOrganization.byDay
        static let dictationOrganization           = NotesOrganization.byMonth
        static let audioImportMaxMB: Int           = 50
        static let meetingDetectInterval: Double   = 3.0    // auto-detect poll seconds
        static let liveBriefMinGrowth: Int         = 350    // chars of new transcript before a brief refresh
        static let transcriptionTimeout: Int       = 30     // seconds for a Groq STT request (live chunk)
        static let importTranscriptionTimeout: Int = 120    // seconds for a whole-file STT request (import)
        static let meetingEndQuietPolls: Int       = 2      // consecutive quiet polls before meeting-end
        static let summaryContextChars: Int        = 24000  // char budget fed to summary/extraction prompts
        static let pttTapThreshold: Double         = 0.4    // seconds: below = tap-lock, above = hold
        static let meetingAutoDetect               = true
        static let voiceCommandsEnabled            = true
        static let voiceCommandRules = """
        "new paragraph" or "new line" → insert a paragraph or line break
        spoken punctuation ("comma", "period", "question mark", "exclamation mark", "colon", "semicolon") → that punctuation character
        "open quote" / "close quote" → quotation marks
        "scratch that" or "delete that" → remove the immediately preceding phrase or sentence
        "all caps <words> end caps" → uppercase those words
        """
        static let streamingDictation              = true
        static let streamChunkSeconds: Double      = 10.0
        static let skipSilentDictation             = true
        static let dictationSilenceThreshold: Float = -45.0
        static let maxSpeakers                     = 4
        static let speakerSensitivity: Double      = 1.0
        static let liveBriefInterval               = 25
        static let aiCacheLimit                    = 500
        static let searchDepth                     = 200
        static let meetingTemplate                 = MeetingTemplate.customerCall
        static let quickNoteNotify                 = true
        static let localOnlyMode                   = false
        static let redactionEnabled                = false
        static let redactEmails                    = true
        static let redactPhones                    = true
        static let redactNumbers                   = true
        static let autoTagging                     = true
        static let errorNotifications              = true
        static let uiDateFormat                    = "dd MMM yyyy"
        static let pdfPaperSize                     = "letter"   // "letter" | "a4"
        static let browserTabDetection             = true
        static let saveDictations                  = true
        static let domainStyleRules = """
        mail.google.com: email
        outlook.office.com: email
        github.com: code
        docs.google.com: notes
        """
        // Estimate defaults (USD) — Groq list prices as of shipping; editable
        // in Settings since provider pricing drifts over time.
        static let priceAudioPerHour               = 0.111   // whisper-large-v3
        static let priceInputPerMTok               = 0.59    // llama-3.3-70b input
        static let priceOutputPerMTok              = 0.79    // llama-3.3-70b output
        static let monthlyBudgetUSD                = 0.0     // 0 = no budget set
        static let webhookEnabled                  = false
        static let webhookURL                      = ""
        static let scriptHookEnabled               = false
        static let scriptHookPath                  = ""
        static let packetIncludeEmail              = true
        static let packetIncludePOC                = true
        static let packetIncludeActions            = true
        static let packetConfirmBeforeRun          = true

        static var notesFolder: URL {
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Notes", isDirectory: true)
        }
    }

    // MARK: - API Models

    /// Groq speech-to-text model used for dictation and meetings.
    var transcriptionModel: String {
        get { string(Key.transcriptionModel, Default.transcriptionModel) }
        set { set(newValue, Key.transcriptionModel) }
    }

    /// Groq LLM used to polish dictated text.
    var polishingModel: String {
        get { string(Key.polishingModel, Default.polishingModel) }
        set { set(newValue, Key.polishingModel) }
    }

    /// Cheap/fast model for lightweight, high-frequency tasks (live brief,
    /// tagging, query expansion, agenda coverage) — keeps cost and latency down.
    var fastModel: String {
        get { string(Key.fastModel, Default.fastModel) }
        set { set(newValue, Key.fastModel) }
    }

    // MARK: - Dictation

    /// CGEvent keycode of the push-to-talk modifier key.
    var pttKeyCode: Int {
        get { int(Key.pttKeyCode, Default.pttKeyCode) }
        set { set(newValue, Key.pttKeyCode) }
    }

    /// How the push-to-talk key activates recording: hold-to-talk, tap-to-lock
    /// (hold still works; a quick tap latches hands-free), or pure toggle.
    var pttActivation: PTTActivation {
        get { PTTActivation(rawValue: string(Key.pttActivation, Default.pttActivation)) ?? .hold }
        set { set(newValue.rawValue, Key.pttActivation) }
    }

    /// Prefer the built-in Mac microphone over Bluetooth mics. Keeps AirPods in
    /// the high-quality A2DP profile (using their mic forces the HFP call profile,
    /// which degrades output quality and shifts volume).
    var preferBuiltInMic: Bool {
        get { bool(Key.preferBuiltInMic, Default.preferBuiltInMic) }
        set { set(newValue, Key.preferBuiltInMic) }
    }

    // MARK: - Meeting Mode

    /// Mic voice threshold in meeting mode, in dBFS (higher = less sensitive).
    var meetingMicThreshold: Float {
        get { float(Key.meetingMicThreshold, Default.meetingMicThreshold) }
        set { set(newValue, Key.meetingMicThreshold) }
    }

    /// System-audio voice threshold in meeting mode, in dBFS.
    var systemAudioThreshold: Float {
        get { float(Key.systemAudioThreshold, Default.systemAudioThreshold) }
        set { set(newValue, Key.systemAudioThreshold) }
    }

    /// Seconds of silence before a speech segment is flushed for transcription.
    var silenceDebounce: TimeInterval {
        get { double(Key.silenceDebounce, Default.silenceDebounce) }
        set { set(newValue, Key.silenceDebounce) }
    }

    /// Maximum segment length before a forced flush (Whisper's ~25s sweet spot).
    var maxSegmentSeconds: TimeInterval {
        get { double(Key.maxSegmentSeconds, Default.maxSegmentSeconds) }
        set { set(newValue, Key.maxSegmentSeconds) }
    }

    /// Whether half-duplex echo suppression is active (built-in speaker mode).
    var echoSuppressionEnabled: Bool {
        get { bool(Key.echoSuppressionEnabled, Default.echoSuppressionEnabled) }
        set { set(newValue, Key.echoSuppressionEnabled) }
    }

    /// How long the mic stays gated after speaker audio, in seconds.
    var echoGateWindow: TimeInterval {
        get { double(Key.echoGateWindow, Default.echoGateWindow) }
        set { set(newValue, Key.echoGateWindow) }
    }

    /// Label used for your own speech in the notes file.
    var speakerLabelYou: String {
        get { string(Key.speakerLabelYou, Default.speakerLabelYou) }
        set { set(newValue, Key.speakerLabelYou) }
    }

    /// Label used for the other participants in the notes file.
    var speakerLabelThem: String {
        get { string(Key.speakerLabelThem, Default.speakerLabelThem) }
        set { set(newValue, Key.speakerLabelThem) }
    }

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
    var captionLingerSeconds: Double {
        get { double(Key.captionLingerSeconds, Default.captionLingerSeconds) }
        set { set(newValue, Key.captionLingerSeconds) }
    }

    /// How many times a failed meeting segment is retried before a failure marker.
    var retryMaxAttempts: Int {
        get { int(Key.retryMaxAttempts, Default.retryMaxAttempts) }
        set { set(newValue, Key.retryMaxAttempts) }
    }

    /// Seconds between retry passes for failed segments.
    var retryIntervalSeconds: Double {
        get { double(Key.retryIntervalSeconds, Default.retryIntervalSeconds) }
        set { set(newValue, Key.retryIntervalSeconds) }
    }

    // MARK: - Meeting Intelligence

    /// Append an AI summary (TL;DR, decisions, action items) when a meeting ends.
    var summariesEnabled: Bool {
        get { bool(Key.summariesEnabled, Default.summariesEnabled) }
        set { set(newValue, Key.summariesEnabled) }
    }

    /// Include an Action Items section in the end-of-meeting summary.
    var actionItemsEnabled: Bool {
        get { bool(Key.actionItemsEnabled, Default.actionItemsEnabled) }
        set { set(newValue, Key.actionItemsEnabled) }
    }

    /// Append Decisions / Risks / Open Questions blocks to the meeting summary.
    var structuredExtraction: Bool {
        get { bool(Key.structuredExtraction, Default.structuredExtraction) }
        set { set(newValue, Key.structuredExtraction) }
    }

    /// Extract meeting-type-specific key fields (deal stage, recommendation,
    /// budget, …) into the front-matter and a Key Details section.
    var extractKeyFields: Bool {
        get { bool(Key.extractKeyFields, Default.extractKeyFields) }
        set { set(newValue, Key.extractKeyFields) }
    }

    /// Extract a list of questions that were raised but never clearly answered.
    var extractUnanswered: Bool {
        get { bool(Key.extractUnanswered, Default.extractUnanswered) }
        set { set(newValue, Key.extractUnanswered) }
    }

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
    var openNotesExternally: Bool {
        get { bool(Key.openNotesExternally, Default.openNotesExternally) }
        set { set(newValue, Key.openNotesExternally) }
    }

    /// Append a topic-chapter jump-list (timestamped) to finished meeting notes.
    var topicChapters: Bool {
        get { bool(Key.topicChapters, Default.topicChapters) }
        set { set(newValue, Key.topicChapters) }
    }

    /// Show a live rolling brief (TL;DR + open action items) during a meeting.
    /// Off by default — it makes periodic LLM calls while the meeting runs.
    var liveAssistantEnabled: Bool {
        get { bool(Key.liveAssistantEnabled, Default.liveAssistantEnabled) }
        set { set(newValue, Key.liveAssistantEnabled) }
    }

    /// Default for the per-meeting "Show prep card" switch — pops a panel of the
    /// linked org/opportunity's recent notes when a meeting starts.
    var meetingPrepCard: Bool {
        get { bool(Key.meetingPrepCard, Default.meetingPrepCard) }
        set { set(newValue, Key.meetingPrepCard) }
    }

    /// Show a notification when meeting notes are saved.
    var notifyOnMeetingEnd: Bool {
        get { bool(Key.notifyOnMeetingEnd, Default.notifyOnMeetingEnd) }
        set { set(newValue, Key.notifyOnMeetingEnd) }
    }

    /// Prepend YAML front-matter (Obsidian/Notion friendly) to notes files.
    var frontMatterEnabled: Bool {
        get { bool(Key.frontMatterEnabled, Default.frontMatterEnabled) }
        set { set(newValue, Key.frontMatterEnabled) }
    }

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

    /// Experimental: label distinct remote speakers (Them / Them 2) by
    /// clustering voice fingerprints (pitch + timbre) per segment.
    var diarizationEnabled: Bool {
        get { bool(Key.diarizationEnabled, Default.diarizationEnabled) }
        set { set(newValue, Key.diarizationEnabled) }
    }

    /// Offer to start Meeting Mode when a conferencing app starts using the mic.
    var meetingAutoDetect: Bool {
        get { bool(Key.meetingAutoDetect, Default.meetingAutoDetect) }
        set { set(newValue, Key.meetingAutoDetect) }
    }

    /// Interpret spoken commands in dictation ("new paragraph", "scratch that").
    var voiceCommandsEnabled: Bool {
        get { bool(Key.voiceCommandsEnabled, Default.voiceCommandsEnabled) }
        set { set(newValue, Key.voiceCommandsEnabled) }
    }

    /// Editable voice-command rules, one per line ("spoken phrase → effect").
    /// Fed verbatim to the polishing model when voice commands are enabled.
    var voiceCommandRules: String {
        get { string(Key.voiceCommandRules, Default.voiceCommandRules) }
        set { set(newValue, Key.voiceCommandRules) }
    }

    /// Transcribe long dictations in chunks while the key is still held.
    var streamingDictation: Bool {
        get { bool(Key.streamingDictation, Default.streamingDictation) }
        set { set(newValue, Key.streamingDictation) }
    }

    /// Chunk length for streaming dictation, in seconds.
    var skipSilentDictation: Bool {
        get { bool(Key.skipSilentDictation, Default.skipSilentDictation) }
        set { set(newValue, Key.skipSilentDictation) }
    }

    /// dBFS floor below which a dictation recording is treated as silence and
    /// never uploaded to Groq. More negative = more sensitive (uploads quieter
    /// audio); less negative = stricter (skips more).
    var dictationSilenceThreshold: Float {
        get { float(Key.dictationSilenceThreshold, Default.dictationSilenceThreshold) }
        set { set(newValue, Key.dictationSilenceThreshold) }
    }

    var streamChunkSeconds: Double {
        get { double(Key.streamChunkSeconds, Default.streamChunkSeconds) }
        set { set(newValue, Key.streamChunkSeconds) }
    }

    /// Voice-separation sensitivity for diarization — the distance threshold
    /// above which a voice is treated as a new speaker. Lower = splits more
    /// eagerly (risks over-splitting one voice); higher = merges similar voices.
    var speakerSensitivity: Double {
        get { double(Key.speakerSensitivity, Default.speakerSensitivity) }
        set { set(newValue, Key.speakerSensitivity) }
    }

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
    var maxSpeakers: Int {
        get { int(Key.maxSpeakers, Default.maxSpeakers) }
        set { set(newValue, Key.maxSpeakers) }
    }

    /// How many recent meetings the Catalog's Meaning search and Ask scan.
    var searchDepth: Int {
        get { int(Key.searchDepth, Default.searchDepth) }
        set { set(newValue, Key.searchDepth) }
    }

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
    var saveDictations: Bool {
        get { bool(Key.saveDictations, Default.saveDictations) }
        set { set(newValue, Key.saveDictations) }
    }

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
    var quickNoteNotify: Bool {
        get { bool(Key.quickNoteNotify, Default.quickNoteNotify) }
        set { set(newValue, Key.quickNoteNotify) }
    }

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
    var browserTabDetection: Bool {
        get { bool(Key.browserTabDetection, Default.browserTabDetection) }
        set { set(newValue, Key.browserTabDetection) }
    }

    /// Newline rules mapping a host substring to a style key, e.g.
    /// "mail.google.com: email". Applied when dictating in a browser.
    var domainStyleRules: String {
        get { string(Key.domainStyleRules, Default.domainStyleRules) }
        set { set(newValue, Key.domainStyleRules) }
    }

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
        if let category = appProfileOverrides[context.bundleID.lowercased()] {
            return .builtIn(category)
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
    var localOnlyMode: Bool {
        get { bool(Key.localOnlyMode, Default.localOnlyMode) }
        set { set(newValue, Key.localOnlyMode) }
    }

    /// Scrub sensitive tokens from transcribed text before it is used.
    var redactionEnabled: Bool {
        get { bool(Key.redactionEnabled, Default.redactionEnabled) }
        set { set(newValue, Key.redactionEnabled) }
    }
    var redactEmails: Bool {
        get { bool(Key.redactEmails, Default.redactEmails) }
        set { set(newValue, Key.redactEmails) }
    }
    var redactPhones: Bool {
        get { bool(Key.redactPhones, Default.redactPhones) }
        set { set(newValue, Key.redactPhones) }
    }
    var redactNumbers: Bool {
        get { bool(Key.redactNumbers, Default.redactNumbers) }
        set { set(newValue, Key.redactNumbers) }
    }

    // MARK: - Cost Estimate Pricing (USD, editable — provider prices drift)

    var priceAudioPerHour: Double {
        get { double(Key.priceAudioPerHour, Default.priceAudioPerHour) }
        set { set(newValue, Key.priceAudioPerHour) }
    }
    var priceInputPerMTok: Double {
        get { double(Key.priceInputPerMTok, Default.priceInputPerMTok) }
        set { set(newValue, Key.priceInputPerMTok) }
    }
    var priceOutputPerMTok: Double {
        get { double(Key.priceOutputPerMTok, Default.priceOutputPerMTok) }
        set { set(newValue, Key.priceOutputPerMTok) }
    }

    /// Soft monthly spend cap in USD. 0 = no budget. When this month's estimated
    /// Groq spend crosses it, GhostWriter warns (banner + one notification).
    var monthlyBudgetUSD: Double {
        get { double(Key.monthlyBudgetUSD, Default.monthlyBudgetUSD) }
        set { set(newValue, Key.monthlyBudgetUSD) }
    }

    // MARK: - Integrations (event hooks)

    /// POST a JSON payload to a user-configured URL when a meeting finishes.
    /// Off by default; suppressed entirely in Local-only mode.
    var webhookEnabled: Bool {
        get { bool(Key.webhookEnabled, Default.webhookEnabled) }
        set { set(newValue, Key.webhookEnabled) }
    }

    /// The destination URL for the outgoing webhook (must be https for it to fire).
    var webhookURL: String {
        get { string(Key.webhookURL, Default.webhookURL) }
        set { set(newValue, Key.webhookURL) }
    }

    /// Run a user-configured local script when a meeting finishes, receiving the
    /// event payload as JSON on stdin. Off by default.
    var scriptHookEnabled: Bool {
        get { bool(Key.scriptHookEnabled, Default.scriptHookEnabled) }
        set { set(newValue, Key.scriptHookEnabled) }
    }

    /// Absolute path to the executable script run on meeting finish.
    var scriptHookPath: String {
        get { string(Key.scriptHookPath, Default.scriptHookPath) }
        set { set(newValue, Key.scriptHookPath) }
    }

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
    var packetConfirmBeforeRun: Bool {
        get { bool(Key.packetConfirmBeforeRun, Default.packetConfirmBeforeRun) }
        set { set(newValue, Key.packetConfirmBeforeRun) }
    }

    // MARK: - Transcription Quality

    /// Fall back to Apple's on-device speech recognition when Groq is unreachable.
    var offlineFallback: Bool {
        get { bool(Key.offlineFallback, Default.offlineFallback) }
        set { set(newValue, Key.offlineFallback) }
    }

    /// Prefer Apple's on-device model for summaries & drafts over Groq, while
    /// still using Groq for transcription. Falls back to Groq if the on-device
    /// model isn't available on this Mac.
    var preferOnDeviceAI: Bool {
        get { bool(Key.preferOnDeviceAI, Default.preferOnDeviceAI) }
        set { set(newValue, Key.preferOnDeviceAI) }
    }

    /// Proactive digest — a scheduled rollup of meetings, open action items, and
    /// quiet relationships.
    var digestEnabled: Bool {
        get { bool(Key.digestEnabled, Default.digestEnabled) }
        set { set(newValue, Key.digestEnabled) }
    }
    var digestFrequency: String {
        get { string(Key.digestFrequency, Default.digestFrequency) }
        set { set(newValue, Key.digestFrequency) }
    }
    var digestHour: Int {
        get { int(Key.digestHour, Default.digestHour) }
        set { set(newValue, Key.digestHour) }
    }
    var digestWeekday: Int {
        get { int(Key.digestWeekday, Default.digestWeekday) }
        set { set(newValue, Key.digestWeekday) }
    }
    var staleRelationshipDays: Int {
        get { int(Key.staleRelationshipDays, Default.staleRelationshipDays) }
        set { set(newValue, Key.staleRelationshipDays) }
    }
    /// "yyyy-MM-dd" of the last generated digest (empty = never). Not user-facing.
    var lastDigestDay: String {
        get { string(Key.lastDigestDay, "") }
        set { set(newValue, Key.lastDigestDay) }
    }

    /// Have the summarizer extract topic tags into the notes front-matter.
    var autoTagging: Bool {
        get { bool(Key.autoTagging, Default.autoTagging) }
        set { set(newValue, Key.autoTagging) }
    }

    /// Post a notification when something fails (also logged in Diagnostics).
    var errorNotifications: Bool {
        get { bool(Key.errorNotifications, Default.errorNotifications) }
        set { set(newValue, Key.errorNotifications) }
    }

    /// DateFormatter pattern for dates shown in the menu and Catalog.
    var uiDateFormat: String {
        get { string(Key.uiDateFormat, Default.uiDateFormat) }
        set { set(newValue, Key.uiDateFormat) }
    }

    /// Paper size for exported PDFs (notes, reports, POCs): "letter" or "a4".
    var pdfPaperSize: String {
        get { string(Key.pdfPaperSize, Default.pdfPaperSize) }
        set { set(newValue, Key.pdfPaperSize) }
    }
    /// Point dimensions (72 dpi) for the chosen paper size — US Letter or A4.
    var pdfPageSize: CGSize {
        pdfPaperSize == "a4" ? CGSize(width: 595, height: 842) : CGSize(width: 612, height: 792)
    }

    /// ISO 639-1 language hint for Whisper (e.g. "en", "de", "ta").
    var transcriptionLanguage: String {
        get { string(Key.transcriptionLanguage, Default.transcriptionLanguage) }
        set { set(newValue, Key.transcriptionLanguage) }
    }

    /// Keep an in-memory list of recent dictations (for recall / ⌃⌥V).
    var dictationHistoryEnabled: Bool {
        get { bool(Key.dictationHistoryOn, Default.dictationHistoryOn) }
        set { set(newValue, Key.dictationHistoryOn) }
    }

    /// How many recent dictations to keep.
    var dictationHistoryLimit: Int {
        get { int(Key.dictationHistoryLimit, Default.dictationHistoryLimit) }
        set { set(newValue, Key.dictationHistoryLimit) }
    }

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
    /// where style ∈ messaging|email|code|browser|notes|general.
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

    /// Style keys valid for a per-app override — the built-in categories only.
    /// (Per-app overrides resolve to an `AppCategory`; custom styles apply via
    /// the global default, not here.)
    var builtInStyleKeys: [(key: String, label: String)] {
        AppCategory.allCases.map { ($0.rawValue, $0.displayName) }
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

    /// Parsed per-app style overrides: bundleID → category.
    var appProfileOverrides: [String: AppCategory] {
        var result: [String: AppCategory] = [:]
        for line in appProfiles.split(whereSeparator: \.isNewline) {
            let parts = line.components(separatedBy: ":")
            guard parts.count == 2,
                  let category = AppCategory(rawValue: parts[1].trimmingCharacters(in: .whitespaces).lowercased())
            else { continue }
            let bundleID = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            guard !bundleID.isEmpty else { continue }
            result[bundleID] = category
        }
        return result
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
    private func float(_ key: String, _ fallback: Float) -> Float {
        defaults.object(forKey: key) == nil ? fallback : defaults.float(forKey: key)
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

// MARK: - Meeting Template

/// Shapes what the end-of-meeting summary extracts. Each template defines its
/// own Markdown sections; Action Items is appended separately when enabled.
/// One machine-readable field a meeting type is worth extracting — captured
/// into the note's YAML front-matter (queryable by Obsidian/Dataview) and, for
/// `.category` fields, mirrored into `tags:` so they're filterable in the
/// Catalog with the existing tag filter.
struct ExtractionField: Hashable {
    enum Kind { case text, category }
    let key: String       // front-matter key suffix, e.g. "deal_stage" → gw_deal_stage
    let label: String     // human label for the Key Details section, e.g. "Deal stage"
    let hint: String      // guidance to the model (allowed values for categories)
    let kind: Kind
}

enum MeetingTemplate: String, CaseIterable, Identifiable {
    // Sales-engineering-focused defaults, plus common team meeting types.
    // (Interview and Retrospective are intentionally not built in — add them
    // as a custom template if needed.)
    case general, customerCall, discovery, solutionDemo, solutionScoping,
         kickoff, planning, standup, oneOnOne, allHands, brainstorm, lecture

    var id: String { rawValue }

    /// Broad category used to group the meeting-type pickers so the list reads
    /// as a few short labeled sections rather than one long wall.
    enum Category: String, CaseIterable {
        case sales, delivery, team, other
        var title: String {
            switch self {
            case .sales:    return "Sales & Customer"
            case .delivery: return "Delivery & Project"
            case .team:     return "Team & Internal"
            case .other:    return "Other"
            }
        }
    }

    var category: Category {
        switch self {
        case .customerCall, .discovery, .solutionDemo, .solutionScoping: return .sales
        case .kickoff, .planning:                                        return .delivery
        case .standup, .oneOnOne, .allHands, .brainstorm:                return .team
        case .lecture, .general:                                         return .other
        }
    }

    /// One-line description shown under the picker to explain what this type
    /// captures and when to reach for it.
    var blurb: String {
        switch self {
        case .general:       return "A neutral catch-all: a short TL;DR plus any decisions."
        case .customerCall:  return "An account call — needs, objections, and commitments, with deal fields."
        case .planning:      return "Scoping/planning — scope, estimates, and risks."
        case .kickoff:       return "A project kickoff — goals, scope, roles, milestones, and risks."
        case .discovery:     return "A discovery call — current state, desired outcomes, and requirements."
        case .solutionDemo:  return "A technical demo — use cases shown, technical fit, and objections."
        case .solutionScoping: return "A solutioning session — requirements, approach, scope, and dependencies."
        case .standup:       return "Daily team sync — per-person updates and blockers."
        case .oneOnOne:      return "A private 1:1 — topics, feedback, and growth notes."
        case .allHands:      return "A team- or company-wide update — announcements, highlights, and Q&A."
        case .brainstorm:    return "An ideation session — every idea plus the promising directions."
        case .lecture:       return "A talk or webinar — key concepts, takeaways, and follow-ups."
        }
    }

    /// The draft documents most useful to produce from this meeting type —
    /// surfaced first in the note viewer's Draft… menu.
    var suggestedDrafts: [FollowUpKind] {
        switch self {
        case .customerCall:    return [.followUpEmail, .proposal, .actionItemList]
        case .discovery:       return [.followUpEmail, .proposal, .pocPlan]
        case .solutionDemo:    return [.followUpEmail, .pocPlan, .proposal]
        case .solutionScoping: return [.pocPlan, .proposal, .actionItemList]
        case .kickoff:         return [.minutes, .actionItemList, .statusUpdate]
        case .planning:        return [.actionItemList, .statusUpdate, .minutes]
        case .standup:         return [.statusUpdate, .actionItemList, .recap]
        case .oneOnOne:        return [.recap, .actionItemList, .thankYou]
        case .allHands:        return [.recap, .faq, .minutes]
        case .brainstorm:      return [.recap, .talkingPoints, .actionItemList]
        case .lecture:         return [.recap, .faq, .actionItemList]
        case .general:         return [.recap, .followUpEmail, .actionItemList]
        }
    }

    /// The high-signal fields this meeting type is worth extracting into the
    /// front-matter. Empty for types where the prose summary already says it
    /// all. `.category` fields are also mirrored into tags for Catalog filtering.
    var keyFields: [ExtractionField] {
        switch self {
        case .customerCall: return [
            .init(key: "deal_stage", label: "Deal stage",
                  hint: "one of: prospecting, discovery, proposal, negotiation, closed-won, closed-lost",
                  kind: .category),
            .init(key: "budget", label: "Budget", hint: "budget or deal size if stated (e.g. $50k)", kind: .text),
            .init(key: "timeline", label: "Timeline", hint: "target date or timeframe if stated (e.g. Q3, by March)", kind: .text),
            .init(key: "decision_maker", label: "Decision maker", hint: "the person who decides, if named", kind: .text),
            .init(key: "next_step", label: "Next step", hint: "the single most important next action", kind: .text),
        ]
        case .planning: return [
            .init(key: "target_date", label: "Target date", hint: "the agreed delivery date or milestone, if stated", kind: .text),
            .init(key: "top_risk", label: "Top risk", hint: "the single biggest risk or dependency", kind: .text),
        ]
        case .oneOnOne: return [
            .init(key: "sentiment", label: "Sentiment",
                  hint: "the report's overall mood: positive, neutral, or concerned", kind: .category),
            .init(key: "focus", label: "Focus next time", hint: "the main topic to revisit next 1:1", kind: .text),
        ]
        case .brainstorm: return [
            .init(key: "top_idea", label: "Most promising idea", hint: "the idea that got the most traction", kind: .text),
        ]
        case .kickoff: return [
            .init(key: "target_date", label: "Target date", hint: "the agreed launch/delivery date or first milestone, if stated", kind: .text),
            .init(key: "top_risk", label: "Top risk", hint: "the single biggest risk or dependency raised", kind: .text),
        ]
        case .discovery: return [
            .init(key: "primary_need", label: "Primary need", hint: "the most important problem the prospect wants solved", kind: .text),
            .init(key: "timeline", label: "Timeline", hint: "target date or timeframe if stated (e.g. Q3, by March)", kind: .text),
            .init(key: "next_step", label: "Next step", hint: "the single most important next action", kind: .text),
        ]
        case .solutionDemo: return [
            .init(key: "technical_fit", label: "Technical fit",
                  hint: "how well the solution matched the requirements: strong, partial, or gaps", kind: .category),
            .init(key: "top_blocker", label: "Top blocker", hint: "the biggest technical objection, gap, or missing capability", kind: .text),
            .init(key: "next_step", label: "Next step", hint: "the single most important next action (e.g. POC, security review)", kind: .text),
        ]
        case .solutionScoping: return [
            .init(key: "scope_clarity", label: "Scope clarity",
                  hint: "how well-defined the scope is: clear, partial, or unclear", kind: .category),
            .init(key: "top_dependency", label: "Top dependency", hint: "the biggest dependency or prerequisite that could block progress", kind: .text),
            .init(key: "next_step", label: "Next step", hint: "the single most important next action", kind: .text),
        ]
        case .general, .standup, .lecture, .allHands:
            return []
        }
    }

    var displayName: String {
        switch self {
        case .general:       return "General"
        case .customerCall:  return "Customer Call"
        case .planning:      return "Planning"
        case .kickoff:       return "Project Kickoff"
        case .discovery:     return "Discovery Call"
        case .solutionDemo:  return "Solution Demo"
        case .solutionScoping: return "Solution Scoping"
        case .standup:       return "Standup"
        case .oneOnOne:      return "1:1"
        case .allHands:      return "All-Hands"
        case .brainstorm:    return "Brainstorm"
        case .lecture:       return "Lecture / Webinar"
        }
    }

    /// The built-in sections for this template, as (heading, instruction)
    /// pairs. Action Items is excluded — it has its own toggle.
    var defaultSections: [(heading: String, instruction: String)] {
        switch self {
        case .general: return [
            ("TL;DR", "2-3 sentences."),
            ("Decisions", "bullet list of decisions made (omit the section if none)."),
        ]
        case .standup: return [
            ("Updates", "one bullet per person: what they did / are doing (use speaker labels when names are unknown)."),
            ("Blockers", "bullet list of blockers raised and who owns unblocking (omit if none)."),
        ]
        case .oneOnOne: return [
            ("Topics", "bullet list of topics discussed."),
            ("Feedback", "feedback exchanged, in either direction (omit if none)."),
            ("Growth & Career", "career/growth notes (omit if none)."),
        ]
        case .customerCall: return [
            ("Customer Needs", "pain points and needs the customer expressed."),
            ("Objections & Concerns", "hesitations or objections raised (omit if none)."),
            ("Commitments", "what was promised to the customer, by whom (omit if none)."),
        ]
        case .planning: return [
            ("Scope", "what was agreed to be in and out of scope."),
            ("Estimates & Commitments", "sizes, dates, owners agreed (omit if none)."),
            ("Risks", "risks and dependencies raised (omit if none)."),
        ]
        case .kickoff: return [
            ("Goals & Success Criteria", "what this project/effort is trying to achieve and how success is measured."),
            ("Scope", "what was agreed to be in and out of scope (omit if not discussed)."),
            ("Roles & Responsibilities", "who owns what — people or teams and their remit."),
            ("Milestones & Timeline", "key dates and milestones agreed (omit if none)."),
            ("Risks & Dependencies", "risks, unknowns, and dependencies raised (omit if none)."),
        ]
        case .discovery: return [
            ("Current State", "the prospect's situation today — how they handle this now, and the pain points."),
            ("Desired Outcomes", "what they want to achieve or change."),
            ("Requirements", "explicit needs, must-haves, and evaluation criteria (omit if none)."),
            ("Constraints", "budget, timeline, or other constraints mentioned (omit if none)."),
        ]
        case .solutionDemo: return [
            ("Use Cases Shown", "the capabilities or workflows demonstrated, and the prospect's reaction to each."),
            ("Technical Fit", "how well the solution matched the stated requirements — what landed well."),
            ("Objections & Gaps", "technical objections, missing capabilities, or concerns raised (omit if none)."),
            ("Next Steps", "agreed follow-ups — POC, security/technical review, further demos — with owners (omit if none)."),
        ]
        case .solutionScoping: return [
            ("Requirements", "the functional and technical requirements the solution must meet."),
            ("Proposed Approach", "the solution or architecture proposed, and how it addresses the requirements."),
            ("In / Out of Scope", "what was agreed to be in scope and explicitly out of scope."),
            ("Dependencies & Prerequisites", "integrations, access, data, or environment needed from either side (omit if none)."),
            // Open Questions is a first-class, toggle-driven section (the same
            // `## Open Questions` checkbox list every meeting type gets) — kept
            // out of the template so it isn't emitted twice and downgraded to
            // plain bullets by the heading-dedup.
        ]
        case .allHands: return [
            ("Announcements", "the key announcements or news shared."),
            ("Highlights", "notable updates, wins, or metrics presented."),
            ("Q&A", "questions raised and the answers given (omit if none)."),
        ]
        case .brainstorm: return [
            ("Ideas", "every distinct idea raised, one bullet each."),
            ("Promising Directions", "the ideas that got traction and why."),
        ]
        case .lecture: return [
            ("Key Concepts", "the main ideas presented, briefly explained."),
            ("Takeaways", "practical takeaways."),
            ("Follow-ups", "questions or topics to research afterward (omit if none)."),
        ]
        }
    }

    /// The default sections as editable text — one `Heading: instruction`
    /// line per section. This is what the Settings editor pre-fills and
    /// resets to.
    var defaultSectionsText: String {
        defaultSections.map { "\($0.heading): \($0.instruction)" }.joined(separator: "\n")
    }

    /// Summary section specs (exact heading + what goes in it) fed to the
    /// model, excluding Action Items. Honors a user override from Settings
    /// when one exists; otherwise uses the built-in defaults.
    var summarySections: [String] {
        if let custom = AppSettings.shared.customTemplateSections(for: self) {
            return Self.parseSections(custom)
        }
        return defaultSections.map { sect($0.heading, $0.instruction) }
    }

    /// Parse `Heading: instruction` lines (the Settings editor format) into
    /// model-facing section specs. Blank lines and lines without a heading
    /// are skipped; a line with no colon is treated as a heading with a
    /// generic instruction.
    static func parseSections(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return nil }
            if let colon = line.firstIndex(of: ":") {
                let heading = line[..<colon].trimmingCharacters(in: .whitespaces)
                let instruction = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                guard !heading.isEmpty else { return nil }
                return sect(heading, instruction.isEmpty ? "the relevant content (omit if none)." : instruction)
            }
            return sect(line, "the relevant content (omit if none).")
        }
    }

    private static func sect(_ heading: String, _ instruction: String) -> String {
        "A section with the exact heading \"## \(heading)\" containing \(instruction)"
    }

    private func sect(_ heading: String, _ instruction: String) -> String {
        Self.sect(heading, instruction)
    }

    /// How a follow-up message for this meeting type should be shaped —
    /// recipient, tone, and what to include. Fed to the follow-up drafter.
    var followUpGuidance: String {
        switch self {
        case .general:
            return "Write a concise recap email to the participants: key outcomes and clear next steps with owners."
        case .standup:
            return "Write a short INTERNAL status update (not a formal email): what's done, what's next, and blockers with owners. Terse and skimmable."
        case .oneOnOne:
            return "Write a brief, warm private recap for the two participants: topics discussed, agreements reached, and any growth/career follow-ups."
        case .allHands:
            return "Write a team-wide recap: the key announcements, highlights, and concise answers to the main questions raised, plus any action items with owners."
        case .brainstorm:
            return "Write a recap: the ideas raised, the most promising directions, and agreed next steps to explore them."
        case .lecture:
            return "Write a learner-oriented recap: key concepts, practical takeaways, and follow-up resources or questions to explore."
        case .customerCall:
            return "Write a polished, client-facing follow-up EMAIL to the customer. Thank them, restate the needs they raised, confirm the commitments made, and lay out next steps with owners and timing. Professional and warm."
        case .planning:
            return "Write an internal follow-up: agreed scope (in/out), estimates and dates, owners, and open risks or dependencies."
        case .kickoff:
            return "Write an internal kickoff recap for the team: the goals and success criteria, agreed scope, who owns what, key milestones and timeline, and open risks or dependencies."
        case .discovery:
            return "Write a follow-up summarizing what you learned: the prospect's current situation and pain points, their desired outcomes, key requirements and constraints, and the proposed next steps. Client-appropriate but grounded strictly in what was said."
        case .solutionDemo:
            return "Write a client-facing follow-up EMAIL after a solution demo: thank them, recap the use cases shown and how they map to the requirements, address any open objections or gaps with clear next steps (POC, technical/security review, further demos) and owners. Professional and confident, grounded strictly in what was demonstrated and discussed."
        case .solutionScoping:
            return "Write a follow-up summarizing the scoping outcome: the agreed requirements, the proposed approach, what's in and out of scope, key dependencies/prerequisites, and open questions with owners. Precise and grounded strictly in what was discussed."
        }
    }

    /// Best-guess template from a finished note's section headings — used when
    /// drafting a follow-up for a past meeting whose template isn't recorded.
    /// Returns nil when nothing distinctive matches (caller falls back).
    static func inferred(fromNotes content: String) -> MeetingTemplate? {
        let lc = content.lowercased()
        func has(_ heading: String) -> Bool { lc.contains("## \(heading.lowercased())") }

        if has("Customer Needs") || has("Objections & Concerns") { return .customerCall }
        if has("Use Cases Shown") || has("Technical Fit") { return .solutionDemo }
        if has("Proposed Approach") || has("In / Out of Scope") { return .solutionScoping }
        if has("Desired Outcomes") || has("Current State") { return .discovery }
        if has("Roles & Responsibilities") || (has("Goals & Success Criteria")) { return .kickoff }
        if has("Announcements") { return .allHands }
        if has("Updates") && has("Blockers") { return .standup }
        if has("Scope") && has("Risks") { return .planning }
        if has("Key Concepts") || has("Takeaways") { return .lecture }
        if has("Promising Directions") { return .brainstorm }
        if has("Growth & Career") { return .oneOnOne }
        return nil
    }
}

// MARK: - User Templates

/// A user-created template: a name plus its editable section text
/// (`Heading: instruction` lines). Persisted as JSON in AppSettings.
struct UserTemplate: Codable, Identifiable, Hashable {
    var id: String        // "user:UUID"
    var name: String
    var sections: String
    /// Optional custom follow-up guidance; empty → a generic default is used.
    /// Defaulted so JSON saved before this field existed still decodes.
    var followUp: String = ""
}

/// A portable bundle of user-customized template data, for Export / Import in
/// the Settings template panes. Every field is defaulted and decoded
/// tolerantly (see `init(from:)`) so a bundle written by any version — or one
/// missing a section — still imports cleanly.
struct TemplateBundle: Codable {
    var version: Int = 1
    var userTemplates: [UserTemplate] = []
    var userDraftTemplates: [UserDraftTemplate] = []
    var meetingSectionOverrides: [String: String] = [:]
    var meetingFollowUpOverrides: [String: String] = [:]
    var draftGuidanceOverrides: [String: String] = [:]

    init(version: Int = 1,
         userTemplates: [UserTemplate] = [],
         userDraftTemplates: [UserDraftTemplate] = [],
         meetingSectionOverrides: [String: String] = [:],
         meetingFollowUpOverrides: [String: String] = [:],
         draftGuidanceOverrides: [String: String] = [:]) {
        self.version = version
        self.userTemplates = userTemplates
        self.userDraftTemplates = userDraftTemplates
        self.meetingSectionOverrides = meetingSectionOverrides
        self.meetingFollowUpOverrides = meetingFollowUpOverrides
        self.draftGuidanceOverrides = draftGuidanceOverrides
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        userTemplates = try c.decodeIfPresent([UserTemplate].self, forKey: .userTemplates) ?? []
        userDraftTemplates = try c.decodeIfPresent([UserDraftTemplate].self, forKey: .userDraftTemplates) ?? []
        meetingSectionOverrides = try c.decodeIfPresent([String: String].self, forKey: .meetingSectionOverrides) ?? [:]
        meetingFollowUpOverrides = try c.decodeIfPresent([String: String].self, forKey: .meetingFollowUpOverrides) ?? [:]
        draftGuidanceOverrides = try c.decodeIfPresent([String: String].self, forKey: .draftGuidanceOverrides) ?? [:]
    }
}

/// A resolved template — built-in or user-defined — that the pickers, the
/// summary prompt, and the section editor all consume uniformly.
enum SummaryTemplate: Identifiable, Hashable {
    case builtIn(MeetingTemplate)
    case user(UserTemplate)

    var id: String {
        switch self {
        case .builtIn(let t): return t.rawValue
        case .user(let t):    return t.id
        }
    }

    var displayName: String {
        switch self {
        case .builtIn(let t): return t.displayName
        case .user(let t):    return t.name
        }
    }

    var isBuiltIn: Bool {
        if case .builtIn = self { return true }
        return false
    }

    /// The editable `Heading: instruction` text — a built-in's override or
    /// defaults, or the user template's own sections.
    var sectionsText: String {
        switch self {
        case .builtIn(let t): return AppSettings.shared.customTemplateSections(for: t) ?? t.defaultSectionsText
        case .user(let t):    return t.sections
        }
    }

    /// The model-facing section specs fed to the summarizer.
    var summarySections: [String] {
        switch self {
        case .builtIn(let t): return t.summarySections
        case .user(let t):    return MeetingTemplate.parseSections(t.sections)
        }
    }

    /// The machine-readable fields to extract for this meeting type. User
    /// templates have no schema yet, so they extract nothing.
    var keyFields: [ExtractionField] {
        switch self {
        case .builtIn(let t): return t.keyFields
        case .user:           return []
        }
    }

    /// Generic follow-up guidance for a user template with no custom text.
    static func genericFollowUp(name: String) -> String {
        "Write a concise follow-up appropriate to a \(name) meeting, building on the notes: key outcomes and clear next steps with owners."
    }

    /// How a follow-up for this meeting type should be shaped — the resolved
    /// guidance fed to the drafter (custom override, then built-in/generic default).
    var followUpGuidance: String {
        switch self {
        case .builtIn(let t): return AppSettings.shared.customTemplateFollowUp(for: t) ?? t.followUpGuidance
        case .user(let t):
            return t.followUp.isEmpty ? Self.genericFollowUp(name: t.name) : t.followUp
        }
    }

    /// The editable follow-up text shown in the editor — a built-in's override
    /// or default, or the user template's own (possibly the generic default).
    var followUpText: String {
        switch self {
        case .builtIn(let t): return AppSettings.shared.customTemplateFollowUp(for: t) ?? t.followUpGuidance
        case .user(let t):    return t.followUp.isEmpty ? Self.genericFollowUp(name: t.name) : t.followUp
        }
    }
}

// MARK: - Dictation Styles

/// A user-created dictation writing style: a name plus its free-text
/// instruction. Persisted as JSON in AppSettings.
struct UserStyle: Codable, Identifiable, Hashable {
    var id: String        // "user:UUID"
    var name: String
    var instruction: String
}

/// A resolved dictation style — a built-in app category or a user style —
/// consumed uniformly by the polisher and the style editor.
enum DictationStyle: Identifiable, Hashable {
    case builtIn(AppCategory)
    case user(UserStyle)

    var id: String {
        switch self {
        case .builtIn(let c): return c.rawValue
        case .user(let s):    return s.id
        }
    }

    var displayName: String {
        switch self {
        case .builtIn(let c): return c.displayName
        case .user(let s):    return s.name
        }
    }

    var isBuiltIn: Bool {
        if case .builtIn = self { return true }
        return false
    }

    /// The writing-style instruction appended to the base polishing prompt —
    /// a built-in's override or default, or the user style's own text.
    var instruction: String {
        switch self {
        case .builtIn(let c): return AppSettings.shared.dictationStyleOverride(for: c) ?? c.defaultInstruction
        case .user(let s):    return s.instruction
        }
    }
}

// MARK: - Notes Organization

/// Folder layout for meeting notes. Applies to new meetings only —
/// existing files stay where they are (all lookups search recursively).
enum NotesOrganization: String, CaseIterable, Identifiable {
    case flat       // everything directly in the notes folder
    case byDay      // Notes/2026/2026-07/03/
    case byMonth    // Notes/2026/2026-07/
    case byYear     // Notes/2026/

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .flat:    return "Single folder"
        case .byDay:   return "Year / month / day (2026/2026-07/03/)"
        case .byMonth: return "Year / month (2026/2026-07/)"
        case .byYear:  return "Year (2026/)"
        }
    }
}

// MARK: - Meeting Overlay Mode

/// Display behavior of the floating overlay during Meeting Mode.
enum MeetingOverlayMode: String, CaseIterable, Identifiable {
    case captions   // pill + live transcript captions
    case minimal    // small recording-indicator pill, no transcript text
    case hidden     // no overlay at all (menu-bar icon is the only indicator)

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .captions: return "Pill with live captions"
        case .minimal:  return "Minimal pill (no captions)"
        case .hidden:   return "Hidden"
        }
    }

    var help: String {
        switch self {
        case .captions: return "Shows the latest transcribed line as it arrives."
        case .minimal:  return "A small recording indicator — nothing readable. Good for screen sharing."
        case .hidden:   return "Nothing on screen. The menu-bar headphones icon is the only sign a meeting is being recorded."
        }
    }
}

// MARK: - Push-to-Talk Key Options

/// Modifier keys usable as the push-to-talk hotkey (flagsChanged-based).
/// How the push-to-talk key drives dictation recording.
enum PTTActivation: String, CaseIterable, Identifiable {
    /// Record only while the key is physically held; stop on release. (Classic push-to-talk.)
    case hold
    /// Hold-to-talk still works, but a quick tap latches recording hands-free
    /// until the next tap. Best of both for short phrases and long dictations.
    case tapLock
    /// Press once to start, press again to stop — the key never needs holding.
    case toggle

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .hold:    return "Hold to talk"
        case .tapLock: return "Tap to lock (hybrid)"
        case .toggle:  return "Press to toggle"
        }
    }

    var detail: String {
        switch self {
        case .hold:    return "Record while the key is held; transcribe and type on release."
        case .tapLock: return "Hold for a quick phrase, or tap once to latch hands-free — tap again (or Esc) to stop."
        case .toggle:  return "Press once to start recording, press again to stop. The key is never held."
        }
    }
}

enum PTTKey: Int, CaseIterable, Identifiable {
    case rightOption  = 61
    case leftOption   = 58
    case rightCommand = 54
    case rightControl = 62
    case fn           = 63

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .rightOption:  return "Right Option (⌥)"
        case .leftOption:   return "Left Option (⌥)"
        case .rightCommand: return "Right Command (⌘)"
        case .rightControl: return "Right Control (⌃)"
        case .fn:           return "Fn (Globe)"
        }
    }

    /// The CGEventFlags mask that indicates this modifier is held down.
    var flagMask: UInt64 {
        switch self {
        case .rightOption, .leftOption: return 0x00080000  // maskAlternate
        case .rightCommand:             return 0x00100000  // maskCommand
        case .rightControl:             return 0x00040000  // maskControl
        case .fn:                       return 0x00800000  // maskSecondaryFn
        }
    }
}
