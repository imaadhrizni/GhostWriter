import Foundation

// MARK: - Digest Service

/// Proactive rollup across recent activity, organised the way you think about
/// it — **grouped by relationship** (Organisation › Project › Opportunity), with
/// each meeting and its open/overdue action items nested underneath, so it's
/// clear *what* happened, *where*, and *which* relationship it relates to.
/// Meetings not linked to the Catalog fall under "Unfiled".
///
/// `buildData` produces the structured model the interactive window renders;
/// `generate` additionally writes an archived Markdown note and posts a
/// click-to-open notification (used by the scheduler).
@MainActor
enum DigestService {

    enum Period: String, CaseIterable {
        case daily, weekly, monthly, yearly

        var label: String { rawValue.capitalized }
        var title: String { "\(label) Digest" }
        /// The calendar span the digest covers, as (component, negative amount).
        var span: (Calendar.Component, Int) {
            switch self {
            case .daily:   return (.day, -1)
            case .weekly:  return (.day, -7)
            case .monthly: return (.month, -1)
            case .yearly:  return (.year, -1)
            }
        }
        /// How many recent meetings to scan (larger periods reach back further).
        var scanLimit: Int {
            switch self {
            case .daily, .weekly: return 60
            case .monthly:        return 250
            case .yearly:         return 1000
            }
        }
    }

    static func period(from raw: String) -> Period { Period(rawValue: raw) ?? .daily }

    /// One meeting and its unfinished action items.
    struct MeetingEntry: Identifiable {
        let id = UUID()
        let file: NotesLibrary.MeetingFile
        let inPeriod: Bool
        let overdue: [NotesLibrary.ActionItem]
        let open: [NotesLibrary.ActionItem]
        var hasOpen: Bool { !overdue.isEmpty || !open.isEmpty }
    }

    /// A relationship (or "Unfiled") with the meetings that belong to it.
    struct Group: Identifiable {
        let id: String            // stable grouping key
        let title: String         // organisation, or "Unfiled"
        let detail: String?       // "Project › Opportunity" / "Direct" / nil
        let tint: String          // "org" | "unfiled" — drives the icon color
        var meetings: [MeetingEntry]

        var periodCount: Int { meetings.filter(\.inPeriod).count }
        var overdueCount: Int { meetings.reduce(0) { $0 + $1.overdue.count } }
        var openCount: Int { meetings.reduce(0) { $0 + $1.open.count } }
    }

    struct StaleRelationship: Identifiable {
        let id = UUID()
        let name: String
        let lastContact: String
        let date: Date
    }

    struct DigestData {
        let period: Period
        let generatedAt: Date
        let groups: [Group]
        let stale: [StaleRelationship]

        var title: String { period.title }
        var periodMeetingCount: Int { groups.reduce(0) { $0 + $1.periodCount } }
        var openActionCount: Int { groups.reduce(0) { $0 + $1.overdueCount + $1.openCount } }
        var isEmpty: Bool { periodMeetingCount == 0 && openActionCount == 0 && stale.isEmpty }
    }

    // MARK: Build

    static func buildData(period: Period) -> DigestData {
        let now = Date()
        let (comp, amount) = period.span
        let since = Calendar.current.date(byAdding: comp, value: amount, to: now) ?? now
        let today = Calendar.current.startOfDay(for: now)

        // Scan recent meetings once; keep those in the period OR carrying open
        // items, and bucket them by relationship.
        var buckets: [String: Group] = [:]
        var order: [String] = []

        for file in NotesLibrary.meetingFiles(limit: period.scanLimit) {
            let inPeriod = (parseDate(file.day) ?? .distantPast) >= since
            var overdue: [NotesLibrary.ActionItem] = [], open: [NotesLibrary.ActionItem] = []
            for item in NotesLibrary.actionItems(inFile: file.url) where !item.done {
                if let due = item.due, let d = parseDate(due), d < today { overdue.append(item) }
                else { open.append(item) }
            }
            guard inPeriod || !overdue.isEmpty || !open.isEmpty else { continue }

            let rel = relationship(forFileURL: file.url)
            let entry = MeetingEntry(file: file, inPeriod: inPeriod, overdue: overdue, open: open)
            if buckets[rel.key] == nil {
                buckets[rel.key] = Group(id: rel.key, title: rel.title, detail: rel.detail,
                                         tint: rel.tint, meetings: [])
                order.append(rel.key)
            }
            buckets[rel.key]?.meetings.append(entry)
        }

        // Named relationships first (by title), Unfiled last.
        let groups = order.compactMap { buckets[$0] }.sorted { a, b in
            if (a.id == "unfiled") != (b.id == "unfiled") { return b.id == "unfiled" }
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }

        return DigestData(period: period, generatedAt: now,
                          groups: groups, stale: staleRelationships(asOf: now))
    }

    /// Resolve a meeting file's relationship path from the Catalog.
    private struct Rel { let key: String; let title: String; let detail: String?; let tint: String }
    private static func relationship(forFileURL url: URL) -> Rel {
        let store = CatalogStore.shared
        let root = AppSettings.shared.notesFolder.path + "/"
        let rel = url.path.replacingOccurrences(of: root, with: "")
        guard let note = store.doc.notes.first(where: { $0.filePath == rel }) else {
            return Rel(key: "unfiled", title: "Unfiled", detail: nil, tint: "unfiled")
        }
        if let oppID = note.opportunityIDs.first, let opp = store.opportunity(oppID) {
            let org = store.org(forOpportunity: opp)
            let proj = store.project(opp.projectID)
            let detail = [proj?.name, opp.name].compactMap { $0 }.joined(separator: " › ")
            return Rel(key: "opp:\(oppID)", title: org?.name ?? opp.name,
                       detail: detail.isEmpty ? nil : detail, tint: "org")
        }
        if let orgID = note.orgIDs.first, let org = store.org(orgID) {
            return Rel(key: "org:\(orgID)", title: org.name, detail: "Direct", tint: "org")
        }
        return Rel(key: "unfiled", title: "Unfiled", detail: nil, tint: "unfiled")
    }

    /// Build, archive, and post the notification. Returns the note URL.
    @discardableResult
    static func generate(period: Period, notify: Bool) -> URL? {
        let data = buildData(period: period)
        guard let url = write(markdown(from: data), at: data.generatedAt) else { return nil }
        if notify { NotificationManager.shared.notifyDigestReady(period: period) }
        return url
    }

    // MARK: Markdown (archived note)

    static func markdown(from d: DigestData) -> String {
        var out = "# \(d.title)\n\n_\(d.generatedAt.formatted(date: .abbreviated, time: .shortened))_\n"
        out += "\n\(d.periodMeetingCount) meeting(s) · \(d.openActionCount) open action item(s)\n"

        if d.groups.isEmpty {
            out += "\n_Nothing to report in this period._\n"
        }
        for g in d.groups {
            out += "\n## \(g.title)\n"
            if let detail = g.detail { out += "_\(detail)_\n" }
            for m in g.meetings {
                out += "\n### \(m.file.displayName)\(m.inPeriod ? "" : "  · earlier")\n"
                if !m.hasOpen { out += "_No open action items._\n"; continue }
                for item in m.overdue { out += actionLine(item, overdue: true) }
                for item in m.open { out += actionLine(item, overdue: false) }
            }
        }

        if !d.stale.isEmpty {
            out += "\n## Quiet Relationships (no contact in \(AppSettings.shared.staleRelationshipDays)+ days)\n\n"
            for s in d.stale { out += "- **\(s.name)** — last note \(s.lastContact)\n" }
        }
        return out
    }

    private static func actionLine(_ item: NotesLibrary.ActionItem, overdue: Bool) -> String {
        var line = "- [ ] \(overdue ? "⚠️ " : "")\(item.displayText)"
        if let owner = item.owner { line += " — @\(owner)" }
        if let due = item.due { line += " _(due \(due))_" }
        return line + "\n"
    }

    // MARK: Stale relationships

    static func staleRelationships(asOf now: Date) -> [StaleRelationship] {
        let store = CatalogStore.shared
        let days = AppSettings.shared.staleRelationshipDays
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: now) else { return [] }

        var out: [StaleRelationship] = []
        for opp in store.doc.opportunities where opp.stage == .open {
            let notes = store.notes(forOpportunity: opp)
            guard !notes.isEmpty, let latest = notes.compactMap(\.date).max(), latest < cutoff else { continue }
            let name = store.org(forOpportunity: opp).map { "\($0.name) · \(opp.name)" } ?? opp.name
            out.append(StaleRelationship(name: name, lastContact: DateDisplay.day(dayString(latest)), date: latest))
        }
        return out.sorted { $0.date > $1.date }
    }

    // MARK: Helpers

    private static func parseDate(_ s: String) -> Date? {
        DateDisplay.posixDay.date(from: String(s.prefix(10)))
    }
    private static func dayString(_ d: Date) -> String { DateDisplay.posixDay.string(from: d) }

    private static func write(_ markdown: String, at date: Date) -> URL? {
        let folder = AppSettings.shared.notesFolder.appendingPathComponent("Digests", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("Digest_\(dayString(date)).md")
        do {
            try markdown.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            Log.app.error("❌ Digest write failed: \(error.localizedDescription)")
            return nil
        }
    }
}
