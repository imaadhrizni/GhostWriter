import Foundation
import NaturalLanguage

// MARK: - Meeting Vocabulary (auto-harvested glossary)
//
// Builds a per-meeting glossary of likely proper nouns — people, orgs,
// products, acronyms — so first-occurrence terms transcribe correctly without
// the user hand-entering anything. This is the "vocabulary" slot of the
// transcription prompt (the rolling transcript is the "context" slot); it
// leads the prompt so Whisper is primed before the term is ever spoken.
//
// The source needs no extra permissions: the user's own past notes. But it is
// scoped to the meeting's PROJECT (and its parent) — never the whole history —
// so terms from unrelated projects (a different customer, your studies) can't
// contaminate the prompt. Manual per-project terms lead, so a brand-new
// project's first call is still seeded before it has any notes.

enum MeetingVocabulary {

    /// Build a scoped seed glossary for a meeting in `projectID`: the project's
    /// (and parent's) manual terms first, then terms harvested on-device from
    /// that project's past notes. Unfiled meetings (nil / unknown project) get
    /// [] — no seed is safer than a cross-project one. Best-effort and bounded.
    static func seed(forProjectID projectID: String?, maxTerms: Int = 40) -> [String] {
        let settings = AppSettings.shared
        guard let projectID, settings.project(withID: projectID) != nil else { return [] }

        let manual = settings.manualTerms(forProjectID: projectID)

        var corpus = ""
        for url in settings.noteFiles(inLineageOf: projectID).prefix(20) {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            corpus += "\n" + text
            if corpus.count > 40_000 { break }   // bound the NER work
        }
        let harvested = extractTerms(from: corpus, maxTerms: maxTerms)

        // Manual terms first — they win when the cap trims the tail.
        var seen = Set<String>()
        var out: [String] = []
        for term in manual + harvested where seen.insert(term.lowercased()).inserted {
            out.append(term)
        }
        return Array(out.prefix(maxTerms))
    }

    /// On-device named-entity + acronym extraction, ranked by frequency.
    /// Pure and side-effect-free so it can be unit-tested directly.
    static func extractTerms(from text: String, maxTerms: Int = 40) -> [String] {
        guard !text.isEmpty else { return [] }

        var counts: [String: Int] = [:]      // key: lowercased term → frequency
        var display: [String: String] = [:]  // key: lowercased term → canonical spelling

        func bump(_ raw: String) {
            let term = raw.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            guard term.count >= 2, term.count <= 40,
                  !acronymStoplist.contains(term.uppercased()) else { return }
            let key = term.lowercased()
            counts[key, default: 0] += 1
            if display[key] == nil { display[key] = term }
        }

        // 1) Named entities: people, organizations, places. `.joinNames` keeps
        //    multi-word names ("Zain Iraq") as a single token.
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        let options: NLTagger.Options = [.omitPunctuation, .omitWhitespace, .joinNames]
        let entityTags: Set<NLTag> = [.personalName, .organizationName, .placeName]
        tagger.enumerateTags(in: text.startIndex..<text.endIndex,
                             unit: .word, scheme: .nameType, options: options) { tag, range in
            if let tag, entityTags.contains(tag) { bump(String(text[range])) }
            return true
        }

        // 2) Acronyms / product tokens NER misses: 2–6 chars with an interior
        //    uppercase or a digit (WSO2, ESB, RFP, TIBCO) — not plain
        //    Capitalized words (those are handled by NER or are common nouns).
        for token in text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let t = String(token)
            guard (2...6).contains(t.count) else { continue }
            let interiorUpper = t.dropFirst().contains { $0.isUppercase }
            let hasDigit = t.contains { $0.isNumber }
            if interiorUpper || hasDigit { bump(t) }
        }

        // Rank by frequency (most-mentioned terms are the meeting's real topics).
        return counts.sorted { $0.value > $1.value }
            .compactMap { display[$0.key] }
            .prefix(maxTerms)
            .map { $0 }
    }

    /// Common all-caps tokens that are not domain terms — filtered from the
    /// acronym pass to keep the seed signal clean.
    private static let acronymStoplist: Set<String> = [
        "OK", "AM", "PM", "TV", "US", "UK", "EU", "IT", "HR", "CEO", "CTO", "CFO",
        "FYI", "ASAP", "ETA", "AKA", "TBD", "TBA", "PDF", "URL", "FAQ"
    ]
}
