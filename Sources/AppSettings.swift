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
        static let pttKeyCode             = "dictation.pttKeyCode"
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
        static let notifyOnMeetingEnd     = "meeting.notifyOnMeetingEnd"
        static let frontMatterEnabled     = "meeting.frontMatterEnabled"
        static let diarizationEnabled     = "meeting.diarizationEnabled"
        static let offlineFallback        = "transcription.offlineFallback"
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
        static let maxSpeakers            = "meeting.maxSpeakers"
        static let actionItemsLookback    = "assistant.actionItemsLookback"
        static let searchDepth            = "assistant.searchDepth"

        static let all = [transcriptionModel, polishingModel, pttKeyCode,
                          preferBuiltInMic,
                          meetingMicThreshold, systemAudioThreshold,
                          silenceDebounce, maxSegmentSeconds, echoGateWindow,
                          echoSuppressionEnabled, speakerLabelYou, speakerLabelThem,
                          notesFolderPath, overlayMode,
                          summariesEnabled, actionItemsEnabled, notifyOnMeetingEnd, frontMatterEnabled,
                          diarizationEnabled, offlineFallback, transcriptionLanguage,
                          vocabulary, replacements, appProfiles,
                          dictationHistoryOn, dictationHistoryLimit,
                          captionLingerSeconds, retryMaxAttempts, retryIntervalSeconds,
                          notesOrganization, meetingAutoDetect,
                          voiceCommandsEnabled, voiceCommandRules, streamingDictation,
                          streamChunkSeconds, maxSpeakers,
                          actionItemsLookback, searchDepth]
    }

    // MARK: - Defaults (previous hard-coded values)

    enum Default {
        static let transcriptionModel              = "whisper-large-v3"
        static let polishingModel                  = "llama-3.3-70b-versatile"
        static let pttKeyCode: Int                 = 61     // Right Option
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
        static let notifyOnMeetingEnd              = true
        static let frontMatterEnabled              = false
        static let diarizationEnabled              = true
        static let offlineFallback                 = true
        static let transcriptionLanguage           = "en"
        static let dictationHistoryOn              = true
        static let dictationHistoryLimit           = 20
        static let captionLingerSeconds: Double    = 6.0
        static let retryMaxAttempts                = 3
        static let retryIntervalSeconds: Double    = 20.0
        static let notesOrganization               = NotesOrganization.byDay
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
        static let maxSpeakers                     = 4
        static let actionItemsLookback             = 10
        static let searchDepth                     = 200

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

    // MARK: - Dictation

    /// CGEvent keycode of the push-to-talk modifier key.
    var pttKeyCode: Int {
        get { int(Key.pttKeyCode, Default.pttKeyCode) }
        set { set(newValue, Key.pttKeyCode) }
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

    /// Folder a *new* meeting's notes file goes into, per the organization
    /// setting (e.g. …/Notes/2026/2026-07/). Existing files are never moved.
    func meetingDestinationFolder(for date: Date = Date()) -> URL {
        // Folder names must be stable across user locales/calendars.
        func stamp(_ format: String) -> String {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = format
            return f.string(from: date)
        }
        let base = notesFolder
        switch notesOrganization {
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
    var streamChunkSeconds: Double {
        get { double(Key.streamChunkSeconds, Default.streamChunkSeconds) }
        set { set(newValue, Key.streamChunkSeconds) }
    }

    /// Maximum distinct remote speakers the diarizer will label.
    var maxSpeakers: Int {
        get { int(Key.maxSpeakers, Default.maxSpeakers) }
        set { set(newValue, Key.maxSpeakers) }
    }

    /// How many recent meetings the Assistant's Action Items tab aggregates.
    var actionItemsLookback: Int {
        get { int(Key.actionItemsLookback, Default.actionItemsLookback) }
        set { set(newValue, Key.actionItemsLookback) }
    }

    /// How many recent meetings full-text search and cross-meeting Ask scan.
    var searchDepth: Int {
        get { int(Key.searchDepth, Default.searchDepth) }
        set { set(newValue, Key.searchDepth) }
    }

    // MARK: - Transcription Quality

    /// Fall back to Apple's on-device speech recognition when Groq is unreachable.
    var offlineFallback: Bool {
        get { bool(Key.offlineFallback, Default.offlineFallback) }
        set { set(newValue, Key.offlineFallback) }
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

    /// Vocabulary flattened to a single Whisper prompt hint (≤400 chars kept).
    var vocabularyPrompt: String {
        let terms = vocabulary
            .components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else { return "" }
        return String("Glossary: " + terms.joined(separator: ", ")).prefix(400).description
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
