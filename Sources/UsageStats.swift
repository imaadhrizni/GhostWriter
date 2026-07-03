import Foundation

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
        static let all = [dictationCount, dictationSeconds, wordsDictated,
                          meetingCount, meetingSeconds]
    }

    private init() {}

    // MARK: - Read

    var dictationCount: Int   { defaults.integer(forKey: Key.dictationCount) }
    var dictationSeconds: Int { defaults.integer(forKey: Key.dictationSeconds) }
    var wordsDictated: Int    { defaults.integer(forKey: Key.wordsDictated) }
    var meetingCount: Int     { defaults.integer(forKey: Key.meetingCount) }
    var meetingSeconds: Int   { defaults.integer(forKey: Key.meetingSeconds) }

    /// Meetings recorded in the last 7 days, derived from notes filenames
    /// (Meeting_yyyy-MM-dd_HH-mm-ss.md) — no extra bookkeeping needed.
    func meetingsThisWeek(in folder: URL) -> Int {
        let formatter = DateFormatter()
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
}
