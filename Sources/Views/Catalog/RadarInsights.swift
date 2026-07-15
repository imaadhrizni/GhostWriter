import SwiftUI

// MARK: - Keyword Radar Insights (Catalog section)
//
// Cross-meeting view of the Keyword Radar, living inside the Catalog (sidebar →
// Tools → Keyword Radar) alongside the POC Tracker and Dashboard — all
// note-analytics in one place. The per-meeting scan already mirrors watchlist
// hits into each note's Mentions section and tags; this aggregates those hits
// across the archive — which terms come up, how often, in how many meetings,
// and when last — with drill-down to the source meetings. Read-only and
// offline: it re-scans note bodies against the current watchlist, so terms
// added later surface retroactively.

// MARK: Aggregation

struct RadarTermStat: Identifiable {
    let term: String
    let total: Int       // total mentions across all scanned meetings
    let meetings: Int    // how many distinct meetings mentioned it
    let lastDay: String  // "yyyy-MM-dd" of the most recent mention
    var id: String { term }
}

struct RadarHit: Identifiable {
    let id = UUID()
    let file: NotesLibrary.MeetingFile
    let title: String
    let day: String
    let count: Int
}

enum RadarInsights {
    struct Result {
        var stats: [RadarTermStat] = []
        var hitsByTerm: [String: [RadarHit]] = [:]
        var scanned: Int = 0
    }

    /// Scan up to `limit` recent meetings for the watchlist terms. Pure/offline;
    /// safe to run off the main thread.
    static func aggregate(watchlist: [String], limit: Int) -> Result {
        guard !watchlist.isEmpty else { return Result() }
        var totals: [String: Int] = [:]
        var meetings: [String: Int] = [:]
        var lastDay: [String: String] = [:]
        var hitsByTerm: [String: [RadarHit]] = [:]
        let files = NotesLibrary.meetingFiles(limit: limit)   // newest-first

        for f in files {
            guard let text = f.url.readText() else { continue }
            let body = FrontMatter.body(text)
            let title = FrontMatter.title(in: text) ?? f.displayName
            let counts = MeetingNotesWriter.mentionCounts(in: body, terms: watchlist)
            for c in counts where c.count > 0 {
                totals[c.term, default: 0] += c.count
                meetings[c.term, default: 0] += 1
                if lastDay[c.term] == nil { lastDay[c.term] = f.day }   // newest-first → first is latest
                hitsByTerm[c.term, default: []].append(
                    RadarHit(file: f, title: title, day: f.day, count: c.count))
            }
        }

        let stats = watchlist.compactMap { term -> RadarTermStat? in
            let t = totals[term] ?? 0
            guard t > 0 else { return nil }
            return RadarTermStat(term: term, total: t,
                                 meetings: meetings[term] ?? 0,
                                 lastDay: lastDay[term] ?? "")
        }.sorted { $0.total > $1.total }

        return Result(stats: stats, hitsByTerm: hitsByTerm, scanned: files.count)
    }
}

/// Shared loaded state so the Catalog's content (term list) and detail
/// (meetings for a term) columns run a single scan between them.
@MainActor
final class RadarModel: ObservableObject {
    @Published var result = RadarInsights.Result()
    @Published var loading = true
    @Published var loaded = false

    func loadIfNeeded() async {
        guard !loaded else { return }
        loading = true
        let terms = AppSettings.shared.watchlist()
        let depth = AppSettings.shared.searchDepth
        let r = await Task.detached(priority: .userInitiated) {
            RadarInsights.aggregate(watchlist: terms, limit: depth)
        }.value
        result = r
        loading = false
        loaded = true
    }

    func reload() async { loaded = false; await loadIfNeeded() }
}

// MARK: Content column — term list

struct RadarTermList: View {
    @ObservedObject var model: RadarModel
    @Binding var selID: String?
    private let watchlist = AppSettings.shared.watchlist()

    var body: some View {
        Group {
            if watchlist.isEmpty {
                empty("No watchlist terms yet",
                      "Add competitors, product names, or risk phrases under Settings → Meetings → Notes & Summaries → Keyword Radar.")
            } else if model.loading {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Scanning meetings…").font(.caption).foregroundColor(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.result.stats.isEmpty {
                empty("No mentions found",
                      "None of your \(watchlist.count) watchlist term\(watchlist.count == 1 ? "" : "s") appeared in the last \(model.result.scanned) meeting\(model.result.scanned == 1 ? "" : "s").")
            } else {
                List(selection: $selID) {
                    Section("Tracked terms · \(model.result.scanned) scanned") {
                        ForEach(model.result.stats) { stat in
                            RadarTermRow(stat: stat, maxTotal: model.result.stats.first?.total ?? 1)
                                .tag(stat.term)
                        }
                    }
                }
            }
        }
        .task { await model.loadIfNeeded() }
        .toolbar {
            ToolbarItem {
                Button { Task { await model.reload() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Rescan meetings")
            }
        }
    }

    private func empty(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.largeTitle).foregroundColor(.secondary)
            Text(title).font(.headline)
            Text(detail).font(.caption).foregroundColor(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 320)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding()
    }
}

// MARK: Detail column — meetings for the selected term

struct RadarTermDetail: View {
    @ObservedObject var model: RadarModel
    let term: String?

    var body: some View {
        if let term, let hits = model.result.hitsByTerm[term], !hits.isEmpty {
            List {
                Section("“\(term)” · \(hits.count) meeting\(hits.count == 1 ? "" : "s")") {
                    ForEach(hits) { hit in
                        Button { NotesViewerWindowController.present(fileURL: hit.file.url) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(hit.title).lineLimit(1)
                                    Text(DateDisplay.day(hit.day))
                                        .font(.caption).foregroundColor(.secondary)
                                }
                                Spacer()
                                Text("×\(hit.count)")
                                    .font(.caption.monospacedDigit()).foregroundColor(.secondary)
                            }
                        }.buttonStyle(.plain)
                    }
                }
            }
            .frame(minWidth: 300)
        } else {
            ContentUnavailableView("Keyword Radar", systemImage: "dot.radiowaves.left.and.right",
                                   description: Text("Select a term to see the meetings that mention it."))
        }
    }
}

/// One term row: name, a proportional bar, and total / meeting counts.
private struct RadarTermRow: View {
    let stat: RadarTermStat
    let maxTotal: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(stat.term).fontWeight(.medium).lineLimit(1)
                Spacer()
                Text("\(stat.total)").font(.callout.monospacedDigit().bold())
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15))
                    Capsule().fill(Color.accentColor.opacity(0.7))
                        .frame(width: geo.size.width * barFraction)
                }
            }
            .frame(height: 4)
            Text("\(stat.meetings) meeting\(stat.meetings == 1 ? "" : "s")\(stat.lastDay.isEmpty ? "" : " · last \(DateDisplay.day(stat.lastDay))")")
                .font(.caption2).foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var barFraction: CGFloat {
        guard maxTotal > 0 else { return 0 }
        return max(0.04, CGFloat(stat.total) / CGFloat(maxTotal))
    }
}
