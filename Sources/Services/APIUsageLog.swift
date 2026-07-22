import Foundation

// MARK: - API Usage Log
//
// A per-call record of every Groq request the app makes — the detailed "where /
// when / which / how much" behind the aggregate counters in UsageStats. Each
// chat and transcription call appends one entry (feature label, model, tokens
// or audio seconds, estimated cost, success/failure) so the user can audit
// exactly what hit the API and from which feature.
//
// Thread-safe (recorded from the background API clients); persisted to
// Application Support (rebuildable, capped ring buffer). A `didLog` notification
// (on the main queue) lets open views refresh live.
final class APIUsageLog {
    static let shared = APIUsageLog()

    /// Posted on the main queue after each entry is recorded.
    static let didLog = Notification.Name("APIUsageLogDidLog")

    enum Kind: String, Codable { case chat, transcription }

    struct Entry: Codable, Identifiable {
        var id = UUID()
        var date: Date
        var kind: Kind
        /// The feature that made the call — "Meeting summary", "Live brief", …
        var source: String
        var model: String
        var inputTokens: Int      // chat only
        var outputTokens: Int     // chat only
        var audioSeconds: Double  // transcription only
        var costUSD: Double
        var ok: Bool
    }

    private let queue = DispatchQueue(label: "com.ghostwriter.apiusagelog")
    private var model: [Entry] = []
    private let url: URL
    private let maxEntries = 2000

    private init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("GhostWriter", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appendingPathComponent("APIUsageLog.json")
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([Entry].self, from: data) {
            model = decoded
        }
    }

    // MARK: Read

    /// All entries, newest first.
    var entries: [Entry] { queue.sync { model.reversed() } }

    // MARK: Record

    func recordChat(source: String, model modelID: String,
                    inputTokens: Int, outputTokens: Int, ok: Bool = true) {
        let s = AppSettings.shared
        let cost = Double(inputTokens) / 1_000_000.0 * s.priceInputPerMTok
                 + Double(outputTokens) / 1_000_000.0 * s.priceOutputPerMTok
        append(Entry(date: Date(), kind: .chat, source: source, model: modelID,
                     inputTokens: inputTokens, outputTokens: outputTokens,
                     audioSeconds: 0, costUSD: cost, ok: ok))
    }

    func recordTranscription(source: String, model modelID: String,
                             audioSeconds: Double, ok: Bool = true) {
        let cost = audioSeconds / 3600.0 * AppSettings.shared.priceAudioPerHour
        append(Entry(date: Date(), kind: .transcription, source: source, model: modelID,
                     inputTokens: 0, outputTokens: 0,
                     audioSeconds: audioSeconds, costUSD: cost, ok: ok))
    }

    func clear() {
        queue.sync { model.removeAll(); persist() }
        NotificationCenter.default.post(name: Self.didLog, object: nil)
    }

    // MARK: Aggregates

    /// Total cost / call count grouped by a key (e.g. source or model).
    func totals(by key: (Entry) -> String) -> [(key: String, count: Int, cost: Double)] {
        let all = entries
        var buckets: [String: (Int, Double)] = [:]
        for e in all {
            let k = key(e)
            let cur = buckets[k] ?? (0, 0)
            buckets[k] = (cur.0 + 1, cur.1 + e.costUSD)
        }
        return buckets.map { ($0.key, $0.value.0, $0.value.1) }
            .sorted { $0.cost > $1.cost }
    }

    // MARK: Private

    private func append(_ entry: Entry) {
        queue.sync {
            model.append(entry)
            if model.count > maxEntries { model.removeFirst(model.count - maxEntries) }
            persist()
        }
        NotificationCenter.default.post(name: Self.didLog, object: nil)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(model) { try? data.write(to: url, options: .atomic) }
    }
}
