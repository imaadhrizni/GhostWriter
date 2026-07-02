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

        static let all = [transcriptionModel, polishingModel, pttKeyCode,
                          preferBuiltInMic,
                          meetingMicThreshold, systemAudioThreshold,
                          silenceDebounce, maxSegmentSeconds, echoGateWindow,
                          echoSuppressionEnabled, speakerLabelYou, speakerLabelThem,
                          notesFolderPath, overlayMode]
    }

    // MARK: - Defaults (previous hard-coded values)

    enum Default {
        static let transcriptionModel              = "whisper-large-v3"
        static let polishingModel                  = "llama-3.3-70b-versatile"
        static let pttKeyCode: Int                 = 61     // Right Option
        static let preferBuiltInMic                = true
        static let meetingMicThreshold: Float      = -40.0
        static let systemAudioThreshold: Float     = -50.0
        static let silenceDebounce: TimeInterval   = 1.5
        static let maxSegmentSeconds: TimeInterval = 25.0
        static let echoGateWindow: TimeInterval    = 0.4
        static let echoSuppressionEnabled          = true
        static let speakerLabelYou                 = "You"
        static let speakerLabelThem                = "Them"
        static let overlayMode                     = MeetingOverlayMode.minimal

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
