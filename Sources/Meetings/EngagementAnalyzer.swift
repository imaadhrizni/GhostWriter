import Foundation

// MARK: - Engagement Analyzer
//
// A local, AI-free read of a finished meeting's transcript: who spoke how much
// (talk share by word count — robust even though lines carry only a start
// timestamp), how many turns and questions each speaker took, the longest
// single monologue, and whether concrete next steps were captured. Rendered as
// a Markdown "# Engagement" section appended alongside the other meeting-end
// sections. Words are the talk-share proxy because transcript lines record only
// a wall-clock start time, so exact per-utterance durations aren't available.

enum EngagementAnalyzer {

    /// One transcript line, parsed into its speaker and text.
    private struct Line { let speaker: String; let text: String }

    /// Matches the canonical transcript line
    /// `**[HH:MM:SS]** **You**: text` (bold = you) or `… _Them_: text` (italic).
    /// Group 1 = bold speaker, group 2 = italic speaker, group 3 = the text.
    private static let lineRegex =
        #/^\*\*\[\d{2}:\d{2}:\d{2}\]\*\*\s+(?:\*\*(.+?)\*\*|_(.+?)_):\s*(.*)$/#

    private struct Stat {
        var words = 0
        var turns = 0
        var questions = 0
    }

    /// Build the Markdown body of the `# Engagement` section from a note's full
    /// content, or nil when there isn't enough dialogue for it to be meaningful
    /// (fewer than two speakers or too few words).
    static func section(fromNote content: String) -> String? {
        let lines = parse(content)
        guard lines.count >= 4 else { return nil }

        // Per-speaker tallies + the longest contiguous monologue (by words).
        var stats: [String: Stat] = [:]
        var order: [String] = []
        var lastSpeaker: String?
        var runWords = 0
        var longest = (speaker: "", words: 0)

        for line in lines {
            if stats[line.speaker] == nil { stats[line.speaker] = Stat(); order.append(line.speaker) }
            let words = line.text.split { $0 == " " || $0.isNewline }.count
            stats[line.speaker]?.words += words
            stats[line.speaker]?.questions += line.text.filter { $0 == "?" }.count
            if line.speaker != lastSpeaker {
                stats[line.speaker]?.turns += 1
                runWords = 0
            }
            runWords += words
            if runWords > longest.words { longest = (line.speaker, runWords) }
            lastSpeaker = line.speaker
        }

        let totalWords = stats.values.reduce(0) { $0 + $1.words }
        guard order.count >= 2, totalWords >= 40 else { return nil }

        // Per-speaker table, ordered by talk share (descending).
        let ranked = order.sorted { (stats[$0]?.words ?? 0) > (stats[$1]?.words ?? 0) }
        var table = "| Speaker | Talk share | Words | Turns | Questions |\n"
        table    += "|---|--:|--:|--:|--:|\n"
        for name in ranked {
            let s = stats[name] ?? Stat()
            let share = Int((Double(s.words) / Double(totalWords) * 100).rounded())
            table += "| \(name) | \(share)% | \(s.words) | \(s.turns) | \(s.questions) |\n"
        }

        let totalQuestions = stats.values.reduce(0) { $0 + $1.questions }
        let nextSteps = capturedNextSteps(in: content)

        var out = table + "\n"
        out += "- **Longest monologue:** \(longest.speaker) (~\(longest.words) words)\n"
        out += "- **Questions asked:** \(totalQuestions)\n"
        out += "- **Next steps captured:** \(nextSteps.map { "Yes — \($0) action item\($0 == 1 ? "" : "s")" } ?? "No")\n\n"
        out += "_Estimated locally from the transcript; talk share is by word count._"
        return out
    }

    // MARK: Internals

    /// Extract the transcript lines (speaker + text) from a note's content.
    private static func parse(_ content: String) -> [Line] {
        content.split(whereSeparator: \.isNewline).compactMap { raw -> Line? in
            let line = String(raw)
            guard line.hasPrefix("**["), let m = try? lineRegex.wholeMatch(in: line) else { return nil }
            let speaker = String(m.1 ?? m.2 ?? "").trimmingCharacters(in: .whitespaces)
            let text = String(m.3).trimmingCharacters(in: .whitespaces)
            guard !speaker.isEmpty else { return nil }
            return Line(speaker: speaker, text: text)
        }
    }

    /// Count of action-item checkboxes in the note, or nil if the note has none
    /// (used for the "next steps captured" signal).
    private static func capturedNextSteps(in content: String) -> Int? {
        let count = content.split(whereSeparator: \.isNewline).filter { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("- [ ]") || t.hasPrefix("- [x]") || t.hasPrefix("- [X]")
        }.count
        return count > 0 ? count : nil
    }
}
