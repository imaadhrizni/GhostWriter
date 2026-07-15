import SwiftUI

// MARK: - Shared date-window filter
//
// A single time-window enum shared by every dated Catalog surface — the
// dashboard's "At a glance" scan, the Notes list, and the Open Questions queue.
// Keeping one type here means the segmented control, the default window, and
// the "is this date in range?" test never drift apart between screens.

enum DateRange: String, CaseIterable, Identifiable {
    case day = "Today", week = "7 days", month = "30 days", quarter = "90 days",
         half = "6 months", year = "1 year", all = "All time"

    var id: String { rawValue }

    /// Length of the window in days; `nil` means "no window" (All time).
    var days: Int? {
        switch self {
        case .day: 1; case .week: 7; case .month: 30; case .quarter: 90
        case .half: 182; case .year: 365; case .all: nil
        }
    }

    /// App-wide default window for dated lists — the last 30 days.
    static let defaultRange: DateRange = .month

    /// Whether `date` falls inside this window relative to `now`. Undated items
    /// are excluded while a window is active and included under "All time".
    func includes(_ date: Date?, now: Date = Date()) -> Bool {
        guard let days else { return true }
        guard let date else { return false }
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: now) ?? now
        return date >= cutoff
    }
}

/// The shared control for picking a `DateRange`. Renders as a segmented control
/// by default (wide canvases like the dashboard); pass `compact: true` for a
/// space-saving dropdown menu used in the narrow Notes column.
struct RangePicker: View {
    @Binding var range: DateRange
    var compact = false

    var body: some View {
        if compact {
            Menu {
                Picker("Range", selection: $range) {
                    ForEach(DateRange.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Label(range.rawValue, systemImage: "calendar")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Time range")
        } else {
            Picker("Range", selection: $range) {
                ForEach(DateRange.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }
    }
}

// MARK: - Year → Month → Day grouping

/// One node in the Year → Month → Day tree. Years/months carry `children`; the
/// day leaves carry `items`. `id` is a stable calendar key ("2026" /
/// "2026-07" / "2026-07-15") so expand/collapse state survives re-grouping.
struct DateGroupNode<Item>: Identifiable {
    let id: String
    let title: String
    let count: Int
    var children: [DateGroupNode<Item>]
    var items: [Item]
}

enum DateGrouping {
    /// Group `items` into a newest-first Year → Month → Day tree. Items whose
    /// date is `nil` collect into a single "Undated" group pinned to the bottom.
    ///
    /// Buckets are keyed off `Calendar.current` components (not a fixed-format
    /// string), so a note's day matches the local calendar day shown by
    /// `Date.formatted(...)` — no UTC/local off-by-one at day boundaries.
    static func tree<Item>(_ items: [Item], dateOf: (Item) -> Date?) -> [DateGroupNode<Item>] {
        let cal = Calendar.current
        // Bucket by local day key, remembering each day's representative date.
        var days: [String: (date: Date, items: [Item])] = [:]
        var undated: [Item] = []
        for item in items {
            guard let d = dateOf(item) else { undated.append(item); continue }
            let c = cal.dateComponents([.year, .month, .day], from: d)
            let key = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
            days[key, default: (d, [])].items.append(item)
        }

        // Assemble years → months → days. Keys are slices of the local day key,
        // titles come from the representative date (also local).
        var years: [String: DateGroupNode<Item>] = [:]
        for (dKey, day) in days {
            let d = day.date
            let yKey = String(dKey.prefix(4))
            let mKey = String(dKey.prefix(7))

            let dayNode = DateGroupNode(id: dKey,
                                        title: d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()),
                                        count: day.items.count, children: [], items: day.items)

            var year = years[yKey] ?? DateGroupNode(id: yKey, title: yKey, count: 0, children: [], items: [])
            if let mi = year.children.firstIndex(where: { $0.id == mKey }) {
                year.children[mi].children.append(dayNode)
            } else {
                year.children.append(DateGroupNode(id: mKey, title: d.formatted(.dateTime.month(.wide)),
                                                   count: 0, children: [dayNode], items: []))
            }
            years[yKey] = year
        }

        // Roll counts up, sort every level newest-first.
        var result = years.values.map { year -> DateGroupNode<Item> in
            var year = year
            year.children = year.children.map { month -> DateGroupNode<Item> in
                var month = month
                month.children.sort { $0.id > $1.id }
                let c = month.children.reduce(0) { $0 + $1.count }
                return DateGroupNode(id: month.id, title: month.title, count: c,
                                     children: month.children, items: [])
            }
            .sorted { $0.id > $1.id }
            let c = year.children.reduce(0) { $0 + $1.count }
            return DateGroupNode(id: year.id, title: year.title, count: c,
                                 children: year.children, items: [])
        }
        result.sort { $0.id > $1.id }
        // Undated items sink below every dated year (id "0000" sorts last).
        if !undated.isEmpty {
            result.append(DateGroupNode(id: "0000", title: "Undated", count: undated.count,
                                        children: [], items: undated))
        }
        return result
    }

    /// Keys open on first load: the newest year, its newest month, and that
    /// month's days — so the most recent notes are visible without any clicks.
    static func defaultExpanded<Item>(_ tree: [DateGroupNode<Item>]) -> Set<String> {
        var keys: Set<String> = []
        guard let year = tree.first else { return keys }
        keys.insert(year.id)
        if let month = year.children.first {
            keys.insert(month.id)
            for day in month.children { keys.insert(day.id) }
        }
        return keys
    }

    /// Every group key at every level — used by "Expand all".
    static func allKeys<Item>(_ nodes: [DateGroupNode<Item>]) -> Set<String> {
        var keys: Set<String> = []
        func walk(_ n: DateGroupNode<Item>) { keys.insert(n.id); n.children.forEach(walk) }
        nodes.forEach(walk)
        return keys
    }
}

/// The one Reset control used across every filterable Catalog view (dashboard,
/// Notes, Map, POC, Keyword Radar) — a single borderless icon so "clear
/// everything back to defaults" looks and sits the same everywhere.
struct ResetButton: View {
    var help: String = "Reset filters"
    let action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: "arrow.uturn.backward") }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(help)
    }
}

/// A compact toggle that expands or collapses every group in a tree at once,
/// sharing the same `expanded` key set as `DateGroupDisclosure`.
struct ExpandCollapseButton<Item>: View {
    let tree: [DateGroupNode<Item>]
    @Binding var expanded: Set<String>

    private var allExpanded: Bool {
        let all = DateGrouping.allKeys(tree)
        return !all.isEmpty && all.isSubset(of: expanded)
    }

    var body: some View {
        Button {
            expanded = allExpanded ? [] : DateGrouping.allKeys(tree)
        } label: {
            Label(allExpanded ? "Collapse All" : "Expand All",
                  systemImage: allExpanded ? "chevron.up.circle" : "chevron.down.circle")
        }
        .help(allExpanded ? "Collapse all groups" : "Expand all groups")
    }
}

// MARK: - Reusable disclosure tree

/// Renders a `DateGroupNode` tree as nested `DisclosureGroup`s with a shared
/// expand/collapse state set. The caller supplies the leaf row for each item,
/// so both a flat selectable notes list and a note→question queue can reuse the
/// same collapsible Year/Month/Day chrome.
struct DateGroupDisclosure<Item: Identifiable, Row: View>: View {
    let nodes: [DateGroupNode<Item>]
    @Binding var expanded: Set<String>
    @ViewBuilder let row: (Item) -> Row

    var body: some View {
        ForEach(nodes) { node in
            NodeView(node: node, level: 0, expanded: $expanded, row: row)
        }
    }

    private struct NodeView: View {
        let node: DateGroupNode<Item>
        let level: Int
        @Binding var expanded: Set<String>
        @ViewBuilder let row: (Item) -> Row

        var body: some View {
            DisclosureGroup(isExpanded: binding) {
                if node.children.isEmpty {
                    ForEach(node.items) { row($0) }
                } else {
                    ForEach(node.children) { child in
                        NodeView(node: child, level: level + 1, expanded: $expanded, row: row)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(node.title)
                        .font(level == 0 ? .subheadline.weight(.semibold) : .subheadline)
                        .foregroundStyle(level == 0 ? .primary : .secondary)
                    Spacer()
                    Text("\(node.count)")
                        .font(.caption2).monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }

        private var binding: Binding<Bool> {
            Binding(get: { expanded.contains(node.id) },
                    set: { if $0 { expanded.insert(node.id) } else { expanded.remove(node.id) } })
        }
    }
}

// MARK: - POC deadline

/// How a POC's target date stands relative to now — drives colour and label
/// wherever a deadline is shown (tracker rows, detail pane, dashboard).
enum DeadlineState {
    case overdue(Int)    // days past
    case dueToday
    case soon(Int)       // within 3 days
    case upcoming(Int)   // further out

    init?(_ deadline: Date?, now: Date = Date()) {
        guard let deadline else { return nil }
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: now),
                                      to: cal.startOfDay(for: deadline)).day ?? 0
        if days < 0        { self = .overdue(-days) }
        else if days == 0  { self = .dueToday }
        else if days <= 3  { self = .soon(days) }
        else               { self = .upcoming(days) }
    }

    var label: String {
        switch self {
        case .overdue(let d):  return "Overdue \(d)d"
        case .dueToday:        return "Due today"
        case .soon(let d), .upcoming(let d): return "Due in \(d)d"
        }
    }

    var color: Color {
        switch self {
        case .overdue:  return .red
        case .dueToday, .soon: return .orange
        case .upcoming: return .secondary
        }
    }

    /// True for anything the user should act on now (overdue / today / soon).
    var isUrgent: Bool { if case .upcoming = self { return false }; return true }
}

/// Compact pill showing a POC deadline's urgency; reused across the tracker,
/// detail pane, and dashboard so due-dates read the same everywhere.
struct DeadlineBadge: View {
    let deadline: Date
    var body: some View {
        let state = DeadlineState(deadline) ?? .upcoming(0)
        HStack(spacing: 3) {
            Image(systemName: "calendar").font(.caption2)
            Text(state.label).font(.caption2.weight(.medium)).lineLimit(1)
        }
        .fixedSize()
        .foregroundStyle(state.color)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule().fill(state.color.opacity(0.12)))
        .help("POC target date: \(deadline.formatted(date: .abbreviated, time: .omitted))")
    }
}
