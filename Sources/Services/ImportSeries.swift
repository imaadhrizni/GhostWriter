import Foundation

// MARK: - Import Series
//
// The pure logic behind "combine these audio files into one note": putting the
// parts in order, stitching their transcripts into a single document, and
// encoding/decoding the list of source files stored in the note's front-matter
// (so a re-selected part is still recognised as already transcribed).
//
// No I/O and no dependencies, so it is unit-testable on its own; the
// orchestration (transcribe → assemble → write → retain audio) lives in
// `AudioImportService`.

/// How the parts of a multi-file import are put in order.
enum PartOrder: String, CaseIterable, Identifiable {
    case fileName      = "File name"
    case recordingDate = "Recording date"
    case manual        = "As arranged"
    var id: String { rawValue }
}

/// One transcribed part of a multi-file import.
struct SeriesPart: Equatable {
    let name: String            // original filename
    let date: Date?             // when it was recorded (file metadata)
    let duration: TimeInterval?
    let bytes: Int?
    let transcript: String      // empty = no speech detected
}

enum ImportSeries {

    // MARK: Ordering

    /// `items` in the requested order. `fileName` uses Finder-style natural
    /// ordering (so "Part 2" sorts before "Part 10"); `recordingDate` puts
    /// undated files last; `manual` keeps the order as given. Ties keep their
    /// original relative order.
    static func ordered<T>(_ items: [T], by order: PartOrder,
                           name: (T) -> String, date: (T) -> Date?) -> [T] {
        guard order != .manual else { return items }
        let indexed = Array(items.enumerated())
        let sorted = indexed.sorted { a, b in
            switch order {
            case .fileName:
                let r = name(a.element).localizedStandardCompare(name(b.element))
                return r == .orderedSame ? a.offset < b.offset : r == .orderedAscending
            case .recordingDate:
                switch (date(a.element), date(b.element)) {
                case let (x?, y?): return x == y ? a.offset < b.offset : x < y
                case (_?, nil):    return true
                case (nil, _?):    return false
                case (nil, nil):   return a.offset < b.offset
                }
            case .manual:
                return a.offset < b.offset
            }
        }
        return sorted.map(\.element)
    }

    // MARK: Assembly

    struct Assembled: Equatable {
        /// The stitched transcript, with a heading per part.
        let transcript: String
        /// Combined length of the parts whose duration is known (nil if none are).
        let duration: TimeInterval?
        /// The earliest recording date among the parts — the note is filed under it.
        let startedAt: Date?
        /// Whether any part contained speech (false = nothing worth a note).
        let hasSpeech: Bool
    }

    /// Stitch ordered parts into one transcript. Each part gets a heading —
    /// `#### Part 2 of 3 — name.m4a · starts at 41:20` (the start offset is
    /// shown while every earlier part's length is known, and Part 1 starts at
    /// 0:00) — so the document keeps its seams and a reader can jump to the right
    /// recording. The offsets also give chapter/summary timestamps something real
    /// to anchor on: with no starting point the model invented a wall-clock time
    /// for the first chapter.
    static func assemble(_ parts: [SeriesPart]) -> Assembled {
        var offset: TimeInterval = 0
        var offsetsKnown = true
        var blocks: [String] = []
        for (i, part) in parts.enumerated() {
            var heading = "#### Part \(i + 1) of \(parts.count) — \(part.name)"
            if offsetsKnown { heading += " · starts at \(clock(offset))" }
            let body = part.transcript.isEmpty ? "_No speech detected in this part._" : part.transcript
            blocks.append(heading + "\n\n" + body)
            if let d = part.duration { offset += d } else { offsetsKnown = false }
        }
        let known = parts.compactMap(\.duration)
        return Assembled(
            transcript: blocks.joined(separator: "\n\n"),
            duration: known.isEmpty ? nil : known.reduce(0, +),
            startedAt: parts.compactMap(\.date).min(),
            hasSpeech: parts.contains { !$0.transcript.isEmpty })
    }

    /// `M:SS`, or `H:MM:SS` from an hour up.
    static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: Source-file list (front-matter)

    /// The note's `gw_source_parts` value: a JSON array of `"name::bytes"`
    /// strings (a valid single-line YAML flow sequence), one per source file.
    static func encodeParts(_ parts: [(name: String, bytes: Int?)]) -> String {
        let entries = parts.map { part in
            part.bytes.map { "\(part.name)::\($0)" } ?? part.name
        }
        guard let data = try? JSONSerialization.data(withJSONObject: entries, options: [.withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }

    /// Whether a stored `gw_source_parts` value includes this file. Matches on
    /// name **and** byte size (same rule as single-file duplicate detection), so
    /// two different clips sharing a name aren't conflated.
    static func contains(_ raw: String?, filename: String, bytes: Int) -> Bool {
        guard let raw, let data = raw.data(using: .utf8),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [String] else { return false }
        return entries.contains("\(filename)::\(bytes)")
    }
}
