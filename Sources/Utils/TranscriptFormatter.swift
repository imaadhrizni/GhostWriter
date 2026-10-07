import Foundation
import NaturalLanguage

// MARK: - Transcript Formatter
//
// Whisper (and Apple's on-device recognizer) return a recording as one
// unbroken block — a ten-minute voice note becomes a single 4,000-character
// paragraph that is miserable to read. `paragraphs` breaks it into readable
// paragraphs without touching a single word: it only inserts blank lines.
//
// It is deterministic, free, and offline (no model call, so no tokens or rate
// limit): sentences come from the NaturalLanguage tokenizer, then are grouped to
// a comfortable length, preferring to start a new paragraph where the speaker
// turns to a new point ("So…", "Now…", "However…"). Unpunctuated run-on speech —
// common in voice notes — has no sentence breaks to use, so an over-long
// "sentence" is cut at a natural pause word ("okay", "right", "so") instead.
//
// Also home to `cleanTitle`, which guards generated titles against a reasoning
// model leaking its thinking into the title field.

enum TranscriptFormatter {

    /// A paragraph that reaches this many characters ends at the next sentence.
    static let targetChars = 420
    /// A paragraph never grows past this (an over-long sentence is cut).
    static let maxChars = 640
    /// Don't start a new paragraph on a marker word until there's this much.
    private static let minForMarkerBreak = 200
    /// A sentence this short ("Okay.", "Right.") attaches to the previous paragraph.
    private static let fillerSentenceChars = 16

    /// Words that, starting a sentence, usually mean the speaker moved on.
    private static let topicMarkers: Set<String> = [
        "so", "now", "also", "but", "however", "anyway", "next", "then", "finally",
        "first", "second", "third", "another", "meanwhile", "overall", "lastly",
        "regarding", "alright", "moving", "secondly", "additionally", "furthermore",
    ]

    /// Words that *close* a thought in unpunctuated speech ("…okay", "…right",
    /// "…correct") — an over-long run-on is cut right after one.
    private static let closingWords: Set<String> = [
        "okay", "ok", "right", "correct", "yeah", "yes", "alright", "fine",
    ]

    // MARK: Paragraphs

    /// `text` with paragraph breaks (blank lines) inserted. Text that already has
    /// paragraph breaks is formatted block by block; empty input is returned as-is.
    static func paragraphs(_ text: String) -> String {
        let blocks = text.components(separatedBy: "\n\n")
        return blocks.map(formatBlock).joined(separator: "\n\n")
    }

    private static func formatBlock(_ block: String) -> String {
        let flat = block.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard flat.count > targetChars / 2 else { return flat }

        var paragraphs: [String] = []
        var current = ""
        for sentence in sentences(in: flat).flatMap(splitRunOn) {
            if current.isEmpty { current = sentence; continue }
            let isFiller = sentence.count <= fillerSentenceChars
            let overflows = current.count + 1 + sentence.count > maxChars
            let full = current.count >= targetChars
            let turn = current.count >= minForMarkerBreak && startsWithMarker(sentence)
            if !isFiller && (overflows || full || turn) {
                paragraphs.append(current)
                current = sentence
            } else if overflows {
                // A filler that would overflow still shouldn't dangle alone.
                paragraphs.append(current)
                current = sentence
            } else {
                current += " " + sentence
            }
        }
        if !current.isEmpty { paragraphs.append(current) }
        return paragraphs.joined(separator: "\n\n")
    }

    /// Sentences via the system tokenizer (handles abbreviations, quotes, numbers).
    private static func sentences(in text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var out: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let s = text[range].trimmingCharacters(in: .whitespaces)
            if !s.isEmpty { out.append(s) }
            return true
        }
        return out.isEmpty ? [text] : out
    }

    private static func startsWithMarker(_ sentence: String) -> Bool {
        guard let first = sentence.split(separator: " ").first else { return false }
        let word = first.trimmingCharacters(in: .punctuationCharacters).lowercased()
        return topicMarkers.contains(word)
    }

    /// Cut a sentence longer than `maxChars` (unpunctuated speech) into pieces.
    /// Once a piece is long enough it ends just *after* a closing word ("okay")
    /// or just *before* a topic marker ("so", "now", "anyway") — a break belongs
    /// where a thought ends or a new one opens — and it never exceeds `maxChars`.
    private static func splitRunOn(_ sentence: String) -> [String] {
        guard sentence.count > maxChars else { return [sentence] }
        let minPiece = targetChars * 2 / 3
        var pieces: [String] = []
        var current: [Substring] = []
        var length = 0
        for word in sentence.split(separator: " ") {
            let bare = word.trimmingCharacters(in: .punctuationCharacters).lowercased()
            // A topic marker opens a new piece — break before it.
            if length >= minPiece, topicMarkers.contains(bare), !current.isEmpty {
                pieces.append(current.joined(separator: " "))
                current = []
                length = 0
            }
            current.append(word)
            length += word.count + 1
            // A closing word ends the piece — break after it.
            if (length >= minPiece && closingWords.contains(bare)) || length >= maxChars {
                pieces.append(current.joined(separator: " "))
                current = []
                length = 0
            }
        }
        if !current.isEmpty {
            // Fold a tiny tail into the previous piece rather than orphaning it.
            if current.count < 6, let last = pieces.popLast() {
                pieces.append(last + " " + current.joined(separator: " "))
            } else {
                pieces.append(current.joined(separator: " "))
            }
        }
        return pieces
    }

    // MARK: Title sanity

    /// A model-generated title made safe to store, or `""` if it isn't a title.
    /// Reasoning models sometimes leave the answer empty and "think" into the
    /// fallback field ("Need concise title. Topic: …"); that must never become a
    /// note's name. Takes the first line, drops wrapping quotes and trailing
    /// punctuation, and rejects anything that reads like reasoning or is too long
    /// to be a title.
    static func cleanTitle(_ raw: String) -> String {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\n").first ?? ""
        let title = line.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’*#. ")
            .union(.whitespaces))
        guard !title.isEmpty, title.count <= 90, title.split(separator: " ").count <= 12 else { return "" }
        return looksLikeReasoning(title) ? "" : title
    }

    /// Whether `text` reads like a reasoning model thinking aloud rather than a
    /// title ("Need concise title. Topic: …", "The user wants…"). Also used when
    /// *showing* a stored title, so notes saved before the guard existed fall back
    /// to their file name instead of displaying the model's thoughts.
    static func looksLikeReasoning(_ text: String) -> Bool {
        let lower = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let openers = ["need ", "we need", "the user", "let's", "let us", "i need", "i should",
                       "okay,", "okay.", "first,", "they want", "must ", "topic:", "title:"]
        return openers.contains { lower.hasPrefix($0) } || lower.contains("topic:")
    }
}
