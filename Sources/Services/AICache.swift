import Foundation
import CryptoKit

// MARK: - AI Cache

/// On-disk cache for expensive, deterministic AI derivations of *immutable*
/// source text — per-note digests, note summaries, and follow-up drafts. A
/// saved note never changes after it's written, so each derivation is a pure
/// function of `(kind, source text, model, prompt version)`; we pay the tokens
/// once and reuse forever.
///
/// Keying on the SHA-256 of the exact source (plus the model id and a per-task
/// prompt version) makes invalidation automatic and correct:
///   • edit a note      → its hash changes      → miss → regenerate
///   • switch the model → the key changes       → miss → regenerate
///   • change a prompt  → bump its version below → miss → regenerate
///
/// Stored in **Application Support** (not Caches, which the OS may purge under
/// disk pressure — which would defeat the point of saving tokens) so cached
/// results survive restarts. Fully regenerable, so it is deliberately left out
/// of the backup bundle.
final class AICache {
    static let shared = AICache()

    /// The kinds of derivation we cache. Each has its own prompt version so a
    /// prompt tweak only invalidates that kind.
    enum Kind: String, Codable {
        case digest      // TextPolisher.meetingDigest — per-note relationship digest
        case summary     // TextPolisher.quickSummary — notes-viewer recap
        case followUp    // TextPolisher.draftFollowUp — meeting follow-up draft
    }

    private struct Entry: Codable {
        let output: String
        let createdAt: Date
    }

    /// Serial queue guards the dictionary and file so any thread can read/write.
    private let queue = DispatchQueue(label: "com.ghostwriter.aicache")
    private var entries: [String: Entry] = [:]
    private let url: URL
    /// Soft cap; oldest entries evict first once exceeded. Generous — the store
    /// is tiny (a few KB per entry) and at real note counts this rarely trips.
    private let maxEntries = 500

    private init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("GhostWriter", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appendingPathComponent("AICache.json")
        load()
    }

    // MARK: Lookup / store

    /// Return the cached output for this exact input, or nil on a miss.
    func value(_ kind: Kind, source: String, model: String, version: Int) -> String? {
        let k = key(kind, source: source, model: model, version: version)
        return queue.sync { entries[k]?.output }
    }

    /// Record a freshly generated output. Evicts oldest entries past the cap.
    func store(_ output: String, kind: Kind, source: String, model: String, version: Int) {
        let k = key(kind, source: source, model: model, version: version)
        queue.sync {
            entries[k] = Entry(output: output, createdAt: Date())
            if entries.count > maxEntries {
                let overflow = entries.count - maxEntries
                for (dk, _) in entries.sorted(by: { $0.value.createdAt < $1.value.createdAt }).prefix(overflow) {
                    entries.removeValue(forKey: dk)
                }
            }
            persist()
        }
    }

    /// Drop everything (used by the "Clear AI cache" control in Settings).
    func clear() {
        queue.sync { entries.removeAll(); persist() }
    }

    /// Number of cached entries — shown next to the clear control.
    var count: Int { queue.sync { entries.count } }

    // MARK: Internals

    private func key(_ kind: Kind, source: String, model: String, version: Int) -> String {
        let digest = SHA256.hash(data: Data(source.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return "\(kind.rawValue):\(version):\(model):\(digest)"
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return }
        entries = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
