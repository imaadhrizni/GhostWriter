import Foundation
import NaturalLanguage

// MARK: - On-Device NLP

/// Metadata extraction that runs entirely on-device with Apple's
/// `NaturalLanguage` framework — no network, no tokens, and available on
/// **every** Mac (unlike the gated Foundation Models LLM). Used two ways:
///   • in Local-only mode, where the cloud is never contacted, and
///   • as a fallback in cloud mode when Groq's metadata call comes back empty.
///
/// Named-entity recognition finds people and organizations; a lexical-class
/// pass surfaces frequent nouns as topic tags. Rougher than the LLM, but free
/// and universal.
enum OnDeviceNLP {

    /// Extract people, the most-mentioned organization (as `customer`), and a
    /// handful of topic tags from a transcript. `includePeople` is dropped when
    /// redaction is on, matching the cloud path.
    static func extractMetadata(transcript: String, includePeople: Bool) -> TextPolisher.MeetingMetadata {
        // Bound the work — NER over a very long transcript is wasteful and the
        // recurring entities show up well within this window.
        let text = String(transcript.prefix(40_000))
        var meta = TextPolisher.MeetingMetadata()

        let (people, orgs) = entities(in: text)
        if includePeople { meta.people = Array(people.prefix(8)) }
        meta.customer = orgs.first
        meta.topics = topicTags(in: text)
        return meta
    }

    // MARK: Named entities

    /// People and organizations, each ranked by how often they're mentioned.
    private static func entities(in text: String) -> (people: [String], orgs: [String]) {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        let options: NLTagger.Options = [.omitPunctuation, .omitWhitespace, .joinNames]

        var peopleCounts: [String: Int] = [:]
        var orgCounts: [String: Int] = [:]
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word,
                             scheme: .nameType, options: options) { tag, range in
            guard let tag else { return true }
            let name = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.count > 1 else { return true }
            switch tag {
            case .personalName:     peopleCounts[name, default: 0] += 1
            case .organizationName: orgCounts[name, default: 0] += 1
            default: break
            }
            return true
        }
        // Most-mentioned first; ties broken alphabetically for determinism.
        func ranked(_ counts: [String: Int]) -> [String] {
            counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
        }
        return (ranked(peopleCounts), ranked(orgCounts))
    }

    // MARK: Topic tags

    /// Frequent, meaningful nouns → lowercase hyphenated tags (e.g. "roadmap",
    /// "multi-tenancy"). A cheap stand-in for the LLM's topic tagging.
    private static func topicTags(in text: String) -> [String] {
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        let options: NLTagger.Options = [.omitPunctuation, .omitWhitespace, .omitOther]

        var counts: [String: Int] = [:]
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word,
                             scheme: .lexicalClass, options: options) { tag, range in
            guard tag == .noun else { return true }
            let word = String(text[range]).lowercased()
            guard word.count > 3, !Self.stopwords.contains(word),
                  word.allSatisfy({ $0.isLetter }) else { return true }
            counts[word, default: 0] += 1
            return true
        }
        return counts
            .filter { $0.value >= 2 }   // must recur to count as a topic
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(6)
            .map { $0.key.replacingOccurrences(of: " ", with: "-") }
    }

    /// Common conversational nouns that make poor tags.
    private static let stopwords: Set<String> = [
        "thing", "things", "stuff", "yeah", "okay", "right", "sure", "kind",
        "lot", "bit", "time", "times", "guy", "guys", "everyone", "everybody",
        "something", "someone", "anything", "anyone", "point", "way", "ways",
        "today", "tomorrow", "week", "meeting", "call", "team", "people",
        "session", "question", "questions", "thanks", "sense",
    ]
}
