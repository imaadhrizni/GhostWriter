import Foundation
import Combine

// MARK: - Usage Stats
//
// Lightweight persisted counters. Deliberately separate from AppSettings so
// "Reset All Settings" doesn't wipe usage history; stats have their own reset.

final class UsageStats: ObservableObject {

    static let shared = UsageStats()
    private let defaults = UserDefaults.standard

    private enum Key {
        static let dictationCount   = "stats.dictationCount"
        static let dictationSeconds = "stats.dictationSeconds"
        static let wordsDictated    = "stats.wordsDictated"
        static let meetingCount     = "stats.meetingCount"
        static let meetingSeconds   = "stats.meetingSeconds"
        static let audioSeconds     = "stats.audioSecondsTranscribed"
        static let inputTokens      = "stats.inputTokens"
        static let outputTokens     = "stats.outputTokens"
        static let all = [dictationCount, dictationSeconds, wordsDictated,
                          meetingCount, meetingSeconds,
                          audioSeconds, inputTokens, outputTokens]
    }

    private init() {}

    // MARK: - Read

    var dictationCount: Int   { defaults.integer(forKey: Key.dictationCount) }
    var dictationSeconds: Int { defaults.integer(forKey: Key.dictationSeconds) }
    var wordsDictated: Int    { defaults.integer(forKey: Key.wordsDictated) }
    var meetingCount: Int     { defaults.integer(forKey: Key.meetingCount) }
    var meetingSeconds: Int   { defaults.integer(forKey: Key.meetingSeconds) }

    /// Groq spend inputs — seconds of audio transcribed, and LLM tokens.
    var audioSecondsTranscribed: Int { defaults.integer(forKey: Key.audioSeconds) }
    var inputTokens: Int             { defaults.integer(forKey: Key.inputTokens) }
    var outputTokens: Int            { defaults.integer(forKey: Key.outputTokens) }

    /// Rough USD estimate of Groq spend, using the editable prices in Settings.
    /// An estimate only — actual billing is authoritative on Groq's console.
    var estimatedCostUSD: Double {
        let s = AppSettings.shared
        let audio = Double(audioSecondsTranscribed) / 3600.0 * s.priceAudioPerHour
        let input = Double(inputTokens) / 1_000_000.0 * s.priceInputPerMTok
        let output = Double(outputTokens) / 1_000_000.0 * s.priceOutputPerMTok
        return audio + input + output
    }

    /// Meetings recorded in the last 7 days, derived from notes filenames
    /// (Meeting_yyyy-MM-dd_HH-mm-ss.md) — no extra bookkeeping needed.
    func meetingsThisWeek(in folder: URL) -> Int {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)

        return MeetingNotesWriter.allMeetingFiles(under: folder).filter { url in
            let stamp = url.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "Meeting_", with: "")
            guard let date = formatter.date(from: stamp) else { return false }
            return date >= cutoff
        }.count
    }

    // MARK: - Record

    func recordDictation(words: Int, seconds: TimeInterval) {
        objectWillChange.send()
        defaults.set(dictationCount + 1, forKey: Key.dictationCount)
        defaults.set(dictationSeconds + Int(seconds.rounded()), forKey: Key.dictationSeconds)
        defaults.set(wordsDictated + words, forKey: Key.wordsDictated)
    }

    func recordMeeting(seconds: TimeInterval) {
        objectWillChange.send()
        defaults.set(meetingCount + 1, forKey: Key.meetingCount)
        defaults.set(meetingSeconds + Int(seconds.rounded()), forKey: Key.meetingSeconds)
    }

    /// Seconds of audio sent to Groq transcription (billed per audio-hour).
    func recordTranscription(audioSeconds: TimeInterval) {
        guard audioSeconds > 0 else { return }
        objectWillChange.send()
        defaults.set(audioSecondsTranscribed + Int(audioSeconds.rounded()), forKey: Key.audioSeconds)
    }

    /// LLM tokens consumed by a chat/completion call (from the API usage field).
    func recordChat(inputTokens promptTokens: Int, outputTokens completionTokens: Int) {
        guard promptTokens > 0 || completionTokens > 0 else { return }
        objectWillChange.send()
        defaults.set(inputTokens + promptTokens, forKey: Key.inputTokens)
        defaults.set(outputTokens + completionTokens, forKey: Key.outputTokens)
    }

    // MARK: - Reset

    func reset() {
        objectWillChange.send()
        Key.all.forEach { defaults.removeObject(forKey: $0) }
    }

    // MARK: - Formatting

    static func hoursMinutes(_ seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    static func currency(_ usd: Double) -> String {
        String(format: "$%.2f", usd)
    }
}
