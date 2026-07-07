import Foundation
import NaturalLanguage

// MARK: - Semantic Index
//
// On-device semantic search over meeting notes. Each note is chunked into a
// handful of overlapping line-windows; every chunk is embedded with Apple's
// NLEmbedding sentence model (free, private, no network). Vectors are cached
// on disk keyed by file path + modification date, so only changed/new notes
// are re-embedded. Queries embed the question and rank chunks by cosine
// similarity. Gracefully no-ops (isAvailable == false) if the OS has no
// sentence-embedding model, and callers fall back to keyword search.

actor SemanticIndex {
    static let shared = SemanticIndex()

    struct Result {
        let url: URL
        let text: String     // the matching chunk (a few transcript lines)
        let score: Float     // cosine similarity, 0…1
    }

    private struct Chunk: Codable {
        let text: String
        let vector: [Float]
        let norm: Float
    }
    private struct FileEntry: Codable {
        let mtime: Date
        let chunks: [Chunk]
    }

    private let embedding = NLEmbedding.sentenceEmbedding(for: .english)
    private var cache: [String: FileEntry] = [:]   // keyed by file path
    private var loaded = false

    /// Cached once, off the actor, so `isAvailable` is callable synchronously.
    private static let sentenceModelExists = NLEmbedding.sentenceEmbedding(for: .english) != nil

    /// False when the OS provides no sentence-embedding model — callers should
    /// fall back to keyword search.
    nonisolated var isAvailable: Bool { Self.sentenceModelExists }

    // MARK: Public API

    /// Rank the most semantically similar chunks to `query` across `files`.
    /// Ensures the index for those files is current first.
    func query(_ query: String, files: [URL], topK: Int) -> [Result] {
        guard let embedding,
              case let q = query.trimmingCharacters(in: .whitespaces), q.count >= 2,
              let qVec = embedding.vector(for: q).map({ $0.map(Float.init) }), !qVec.isEmpty
        else { return [] }
        let qNorm = norm(qVec)
        guard qNorm > 0 else { return [] }

        refresh(files: files)

        var scored: [Result] = []
        let wanted = Set(files.map(\.path))
        for (path, entry) in cache where wanted.contains(path) {
            let url = URL(fileURLWithPath: path)
            for chunk in entry.chunks where chunk.norm > 0 {
                let sim = dot(qVec, chunk.vector) / (qNorm * chunk.norm)
                scored.append(Result(url: url, text: chunk.text, score: sim))
            }
        }
        return Array(scored.sorted { $0.score > $1.score }.prefix(topK))
    }

    // MARK: Indexing

    /// Bring the cache in sync with `files`: (re)embed any new or modified
    /// file, drop entries for files no longer present, and persist once.
    private func refresh(files: [URL]) {
        guard let embedding else { return }
        loadIfNeeded()

        var changed = false

        // Drop stale entries (deleted / rolled off the recent window is fine to keep,
        // but prune anything not on disk anymore to bound the cache).
        // Snapshot the keys first — mutating `cache` while iterating its live
        // keys view is undefined behavior.
        for path in Array(cache.keys) where !FileManager.default.fileExists(atPath: path) {
            cache[path] = nil; changed = true
        }

        for url in files {
            let path = url.path
            let mtime = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? nil
            guard let mtime else { continue }
            if let existing = cache[path], abs(existing.mtime.timeIntervalSince(mtime)) < 1 { continue }
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }

            let chunks = Self.chunk(content).compactMap { text -> Chunk? in
                guard let v = embedding.vector(for: text) else { return nil }
                let fv = v.map(Float.init)
                return Chunk(text: text, vector: fv, norm: norm(fv))
            }
            cache[path] = FileEntry(mtime: mtime, chunks: chunks)
            changed = true
        }
        if changed { persist() }
    }

    /// Split a note into overlapping windows of a few non-empty content lines,
    /// skipping YAML front-matter and Markdown structure noise.
    static func chunk(_ content: String, linesPerChunk: Int = 6, stride: Int = 4) -> [String] {
        var body = content
        // Drop leading YAML front-matter.
        if body.hasPrefix("---"), let end = body.range(of: "\n---", range: body.index(body.startIndex, offsetBy: 3)..<body.endIndex) {
            body = String(body[end.upperBound...])
        }
        let lines = body
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "---" }
        guard !lines.isEmpty else { return [] }

        var chunks: [String] = []
        var i = 0
        while i < lines.count {
            let window = lines[i..<min(i + linesPerChunk, lines.count)].joined(separator: " ")
            let trimmed = window.count > 1_200 ? String(window.prefix(1_200)) : window
            if trimmed.count >= 12 { chunks.append(trimmed) }
            if i + linesPerChunk >= lines.count { break }
            i += stride
        }
        return chunks
    }

    // MARK: Persistence

    private var cacheURL: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GhostWriter", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("semantic-index.json")
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        if let data = try? Data(contentsOf: cacheURL),
           let decoded = try? JSONDecoder().decode([String: FileEntry].self, from: data) {
            cache = decoded
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(cache) {
            try? data.write(to: cacheURL, options: .atomic)
        }
    }

    // MARK: Vector math

    private func dot(_ a: [Float], _ b: [Float]) -> Float {
        let n = min(a.count, b.count)
        var s: Float = 0
        for i in 0..<n { s += a[i] * b[i] }
        return s
    }
    private func norm(_ a: [Float]) -> Float {
        var s: Float = 0
        for x in a { s += x * x }
        return s.squareRoot()
    }
}
