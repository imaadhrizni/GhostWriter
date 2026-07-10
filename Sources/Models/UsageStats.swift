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
        // Per-calendar-month spend inputs, reset on month rollover.
        static let monthAnchor      = "stats.monthAnchor"          // "yyyy-MM"
        static let monthAudioSeconds = "stats.month.audioSeconds"
        static let monthInputTokens  = "stats.month.inputTokens"
        static let monthOutputTokens = "stats.month.outputTokens"
        static let budgetWarnedMonth = "stats.budgetWarnedMonth"   // "yyyy-MM" already warned
        static let all = [dictationCount, dictationSeconds, wordsDictated,
                          meetingCount, meetingSeconds,
                          audioSeconds, inputTokens, outputTokens,
                          monthAnchor, monthAudioSeconds, monthInputTokens,
                          monthOutputTokens, budgetWarnedMonth]
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

    // MARK: - Monthly spend & budget

    /// Current calendar month key, e.g. "2026-07".
    private var currentMonthKey: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM"
        return f.string(from: Date())
    }

    /// Reset the month counters when the calendar month changes.
    private func rollMonthIfNeeded() {
        let now = currentMonthKey
        guard defaults.string(forKey: Key.monthAnchor) != now else { return }
        defaults.set(now, forKey: Key.monthAnchor)
        defaults.set(0, forKey: Key.monthAudioSeconds)
        defaults.set(0, forKey: Key.monthInputTokens)
        defaults.set(0, forKey: Key.monthOutputTokens)
    }

    /// Estimated Groq spend so far this calendar month (same pricing as the
    /// lifetime estimate, but over the month-to-date counters).
    var costThisMonthUSD: Double {
        // A read shouldn't mutate; if the month rolled over the stored counters
        // are last month's, so treat a stale anchor as $0 this month.
        guard defaults.string(forKey: Key.monthAnchor) == currentMonthKey else { return 0 }
        let s = AppSettings.shared
        let audio = Double(defaults.integer(forKey: Key.monthAudioSeconds)) / 3600.0 * s.priceAudioPerHour
        let input = Double(defaults.integer(forKey: Key.monthInputTokens)) / 1_000_000.0 * s.priceInputPerMTok
        let output = Double(defaults.integer(forKey: Key.monthOutputTokens)) / 1_000_000.0 * s.priceOutputPerMTok
        return audio + input + output
    }

    /// Fraction of the monthly budget used (0…1+); nil when no budget is set.
    var budgetFraction: Double? {
        let budget = AppSettings.shared.monthlyBudgetUSD
        guard budget > 0 else { return nil }
        return costThisMonthUSD / budget
    }

    /// True once this month's spend has crossed the configured budget.
    var isOverBudget: Bool { (budgetFraction ?? 0) >= 1.0 }

    /// Call after recording spend: returns true exactly once per month, the
    /// first time the budget is crossed, so the caller can fire a single warning.
    func shouldWarnBudgetOnce() -> Bool {
        guard isOverBudget else { return false }
        guard defaults.string(forKey: Key.budgetWarnedMonth) != currentMonthKey else { return false }
        defaults.set(currentMonthKey, forKey: Key.budgetWarnedMonth)
        return true
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
        rollMonthIfNeeded()
        let secs = Int(audioSeconds.rounded())
        defaults.set(audioSecondsTranscribed + secs, forKey: Key.audioSeconds)
        defaults.set(defaults.integer(forKey: Key.monthAudioSeconds) + secs, forKey: Key.monthAudioSeconds)
    }

    /// LLM tokens consumed by a chat/completion call (from the API usage field).
    func recordChat(inputTokens promptTokens: Int, outputTokens completionTokens: Int) {
        guard promptTokens > 0 || completionTokens > 0 else { return }
        objectWillChange.send()
        rollMonthIfNeeded()
        defaults.set(inputTokens + promptTokens, forKey: Key.inputTokens)
        defaults.set(outputTokens + completionTokens, forKey: Key.outputTokens)
        defaults.set(defaults.integer(forKey: Key.monthInputTokens) + promptTokens, forKey: Key.monthInputTokens)
        defaults.set(defaults.integer(forKey: Key.monthOutputTokens) + completionTokens, forKey: Key.monthOutputTokens)
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
