import Foundation
import NaturalLanguage

// MARK: - Semantic Index
//
// On-device hybrid search over meeting notes. Each note is chunked into a
// handful of overlapping line-windows; the chunk text is always kept, and when
// the OS provides a sentence-embedding model each chunk is also embedded with
// Apple's NLEmbedding (free, private, no network). The index is cached on disk
// keyed by file path + modification date, so only changed/new notes are
// re-processed.
//
// Retrieval blends two signals: cosine similarity of the embeddings (meaning)
// and a BM25 lexical score over the chunk text (exact words, names, IDs). The
// blend is reranked with an exact-phrase bonus and a mild recency boost. When
// no embedding model exists the lexical half still runs, so search and Ask keep
// working — they just lose the meaning half.

actor SemanticIndex {
    static let shared = SemanticIndex()

    struct Result {
        let url: URL
        let text: String        // the matching chunk (a few transcript lines)
        let score: Float         // blended relevance, roughly 0…1
        let matched: [String]    // query terms present in this chunk (for highlighting)
    }

    private struct Chunk: Codable {
        let text: String
        let vector: [Float]?     // nil when no embedding model was available
        let norm: Float          // 0 when there's no vector
        /// Lowercased term-frequency table, precomputed for BM25.
        let terms: [String: Int]
        let length: Int          // total token count (BM25 length normalization)
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

    /// Whether the meaning (embedding) half of retrieval is available. Lexical
    /// search runs regardless, so callers no longer need to gate on this.
    nonisolated var isAvailable: Bool { Self.sentenceModelExists }

    // MARK: Public API

    /// Rank the most relevant chunks to `query` across `files`, blending
    /// semantic similarity (when available) with a BM25 lexical score, then
    /// reranking with an exact-phrase bonus and a recency boost.
    func query(_ query: String, files: [URL], topK: Int) -> [Result] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return [] }

        refresh(files: files)

        // Gather the candidate chunks in scope.
        let wanted = Set(files.map(\.path))
        var candidates: [(url: URL, chunk: Chunk, mtime: Date)] = []
        for (path, entry) in cache where wanted.contains(path) {
            let url = URL(fileURLWithPath: path)
            for chunk in entry.chunks { candidates.append((url, chunk, entry.mtime)) }
        }
        guard !candidates.isEmpty else { return [] }

        // ── Semantic scores (0…1), when an embedding model exists ──────────
        var semantic = [Float](repeating: 0, count: candidates.count)
        var haveSemantic = false
        if let embedding,
           let qv = embedding.vector(for: q).map({ $0.map(Float.init) }), !qv.isEmpty {
            let qNorm = norm(qv)
            if qNorm > 0 {
                haveSemantic = true
                for (i, c) in candidates.enumerated() {
                    guard let v = c.chunk.vector, c.chunk.norm > 0 else { continue }
                    semantic[i] = max(0, dot(qv, v) / (qNorm * c.chunk.norm))
                }
            }
        }

        // ── Lexical BM25 scores ────────────────────────────────────────────
        let queryTerms = Self.tokenize(q)
        var lexical = [Float](repeating: 0, count: candidates.count)
        var maxLex: Float = 0
        if !queryTerms.isEmpty {
            let n = Float(candidates.count)
            let avgLen = Float(candidates.reduce(0) { $0 + $1.chunk.length }) / n
            // Document frequency per unique query term.
            let uniqueTerms = Set(queryTerms)
            var df: [String: Int] = [:]
            for term in uniqueTerms {
                df[term] = candidates.reduce(0) { $0 + ($1.chunk.terms[term] != nil ? 1 : 0) }
            }
            let k1: Float = 1.2, b: Float = 0.75
            for (i, c) in candidates.enumerated() {
                var s: Float = 0
                let len = Float(max(c.chunk.length, 1))
                for term in uniqueTerms {
                    guard let tf = c.chunk.terms[term], tf > 0 else { continue }
                    let dfT = Float(df[term] ?? 1)
                    let idf = log(1 + (n - dfT + 0.5) / (dfT + 0.5))
                    let f = Float(tf)
                    s += idf * (f * (k1 + 1)) / (f + k1 * (1 - b + b * len / avgLen))
                }
                lexical[i] = s
                maxLex = max(maxLex, s)
            }
        }

        // ── Blend + rerank ──────────────────────────────────────────────────
        // Weight meaning higher when embeddings exist; lexical carries it alone
        // otherwise. Add an exact-phrase bonus and a small recency boost.
        let phrase = q.lowercased()
        let phraseWorthMatching = queryTerms.count >= 2
        let now = candidates.map(\.mtime).max() ?? Date()
        let semWeight: Float = haveSemantic ? 0.65 : 0
        let lexWeight: Float = haveSemantic ? 0.35 : 1.0

        var scored: [Result] = []
        scored.reserveCapacity(candidates.count)
        for (i, c) in candidates.enumerated() {
            let lex = maxLex > 0 ? lexical[i] / maxLex : 0
            let base = semWeight * semantic[i] + lexWeight * lex
            // No relevance signal → drop it (don't let the recency boost alone
            // float every chunk in scope into the results).
            guard base > 0.001 else { continue }
            var score = base
            let lowerText = c.chunk.text.lowercased()
            if phraseWorthMatching && lowerText.contains(phrase) { score += 0.15 }
            // Recency: newest scope files nudged up, tapering over ~180 days.
            let ageDays = Float(now.timeIntervalSince(c.mtime) / 86_400)
            score += 0.06 * max(0, 1 - ageDays / 180)
            let matched = queryTerms.filter { c.chunk.terms[$0] != nil }
            scored.append(Result(url: c.url, text: c.chunk.text, score: score, matched: Array(Set(matched))))
        }
        return Array(scored.sorted { $0.score > $1.score }.prefix(topK))
    }

    // MARK: Indexing

    /// Bring the cache in sync with `files`: (re)process any new or modified
    /// file, drop entries for files no longer present, and persist once.
    private func refresh(files: [URL]) {
        loadIfNeeded()

        var changed = false

        // Prune entries whose file is gone, to bound the cache.
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
            guard let content = url.readText() else { continue }

            let chunks = Self.chunk(content).map { text -> Chunk in
                let fv = embedding?.vector(for: text).map { $0.map(Float.init) }
                let toks = Self.tokenize(text)
                var tf: [String: Int] = [:]
                for t in toks { tf[t, default: 0] += 1 }
                return Chunk(text: text,
                             vector: fv,
                             norm: fv.map(norm) ?? 0,
                             terms: tf,
                             length: toks.count)
            }
            cache[path] = FileEntry(mtime: mtime, chunks: chunks)
            changed = true
        }
        if changed { persist() }
    }

    /// Split a note into overlapping windows of a few non-empty content lines,
    /// skipping YAML front-matter and Markdown structure noise.
    static func chunk(_ content: String, linesPerChunk: Int = 6, stride: Int = 4) -> [String] {
        // Drop leading YAML front-matter.
        let lines = FrontMatter.body(content)
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

    // MARK: Tokenization (lexical)

    /// Common English stopwords dropped from lexical indexing/queries so they
    /// don't dominate BM25 or count as "matched" terms for highlighting.
    private static let stopwords: Set<String> = [
        "the", "and", "for", "are", "was", "with", "that", "this", "have", "has",
        "had", "not", "but", "you", "your", "our", "their", "his", "her", "its",
        "from", "into", "about", "what", "when", "where", "which", "who", "how",
        "did", "does", "will", "would", "can", "could", "should", "there", "here",
        "they", "them", "then", "than", "were", "been", "being", "any", "all",
    ]

    /// Lowercase, split on non-alphanumerics, drop stopwords and 1-char tokens.
    static func tokenize(_ s: String) -> [String] {
        s.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 2 && !stopwords.contains($0) }
    }

    // MARK: Persistence

    private var cacheURL: URL {
        // v2: chunk format now carries lexical term tables + optional vectors.
        AppPaths.caches().appendingPathComponent("semantic-index-v2.json")
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        // Remove the pre-v2 index (cosine-only chunk format) — superseded by
        // the hybrid v2 cache, so it would just sit orphaned.
        let legacy = cacheURL.deletingLastPathComponent().appendingPathComponent("semantic-index.json")
        try? FileManager.default.removeItem(at: legacy)
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
