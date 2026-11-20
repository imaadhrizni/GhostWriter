import Foundation

// MARK: - Action Item Query
//
// The filter / group / count logic behind Catalog → Action Items, as pure value
// code (no UI, no files) so it can be tested on its own. The screen builds
// `ActionEntry` values from the notes and asks this for what to show.

/// One action item with the context the screen filters and groups on.
struct ActionEntry: Identifiable, Equatable {
    let id: UUID
    var text: String                 // the action, chips removed
    var owner: String?
    var dueText: String?             // as written ("tomorrow", "2026-11-10")
    var due: Date?                   // resolved calendar day, when it could be
    var done: Bool
    var noteKey: String              // stable key for the source note (its path)
    var noteTitle: String
    var noteDate: Date?
    var account: String              // organisation name, or "Unfiled"
    var project: String?
    var orgIDs: Set<String>
    var projIDs: Set<String>
}

/// Where an item sits relative to today.
enum ActionBucket: Int, CaseIterable, Identifiable {
    case overdue, today, thisWeek, later, noDate, done
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .overdue: return "Overdue"
        case .today:   return "Today"
        case .thisWeek: return "Next 7 days"
        case .later:   return "Later"
        case .noDate:  return "No due date"
        case .done:    return "Done"
        }
    }
}

/// Which items to list.
enum ActionStatus: String, CaseIterable, Identifiable {
    case open = "Open", overdue = "Overdue", dueSoon = "Due soon", noDate = "No due date", done = "Done", all = "All"
    var id: String { rawValue }
}

enum ActionGrouping: String, CaseIterable, Identifiable {
    case none = "None", due = "Due date", owner = "Owner", account = "Account", meeting = "Meeting"
    var id: String { rawValue }
}

/// How items are ordered *within* each group — independent of the grouping and
/// of the filters, so any combination works.
enum ActionSort: String, CaseIterable, Identifiable {
    case due = "Due date", meeting = "Meeting date", owner = "Owner", account = "Account", text = "Name"
    var id: String { rawValue }
    /// Ascending reads naturally as "soonest / oldest / A–Z first"; the toolbar's
    /// direction toggle flips it.
    func label(ascending: Bool) -> String {
        switch self {
        case .due:     return ascending ? "Soonest first" : "Latest first"
        case .meeting: return ascending ? "Oldest first" : "Newest first"
        default:       return ascending ? "A → Z" : "Z → A"
        }
    }
}

struct ActionFilter: Equatable {
    var status: ActionStatus = .open
    /// nil = anyone; `ActionFilter.unassigned` = items with no owner; otherwise the
    /// owner names to match (case-insensitive) — several for "Me" (your labels/names).
    var owners: Set<String>? = nil
    var scopeKind = ""               // "", "org", "project"
    var scopeID = ""
    var meetingWithinDays: Int? = nil
    var query = ""

    static let unassigned = "\u{1}unassigned"
}

enum ActionQuery {

    /// How far ahead "due soon" looks (days, including today).
    static let soonDays = 7

    static func bucket(of e: ActionEntry, today: Date, calendar: Calendar = .current) -> ActionBucket {
        if e.done { return .done }
        guard let due = e.due else { return .noDate }
        let day = calendar.startOfDay(for: due)
        if day < today { return .overdue }
        if day == today { return .today }
        let horizon = calendar.date(byAdding: .day, value: soonDays, to: today) ?? today
        return day <= horizon ? .thisWeek : .later
    }

    private static func matches(_ status: ActionStatus, _ b: ActionBucket) -> Bool {
        switch status {
        case .open:    return b != .done
        case .overdue: return b == .overdue
        case .dueSoon: return b == .today || b == .thisWeek
        case .noDate:  return b == .noDate
        case .done:    return b == .done
        case .all:     return true
        }
    }

    /// Every filter except the status — the base for the per-status counts.
    private static func passes(_ e: ActionEntry, _ f: ActionFilter, now: Date, calendar: Calendar) -> Bool {
        if let owners = f.owners {
            if owners.contains(ActionFilter.unassigned) {
                if e.owner != nil && !owners.subtracting([ActionFilter.unassigned]).contains(where: { $0.caseInsensitiveCompare(e.owner ?? "") == .orderedSame }) { return false }
            } else {
                guard let o = e.owner, owners.contains(where: { $0.caseInsensitiveCompare(o) == .orderedSame }) else { return false }
            }
        }
        if f.scopeKind == "org", !e.orgIDs.contains(f.scopeID) { return false }
        if f.scopeKind == "project", !e.projIDs.contains(f.scopeID) { return false }
        if let days = f.meetingWithinDays {
            guard let d = e.noteDate else { return false }
            let cutoff = calendar.date(byAdding: .day, value: -days, to: now) ?? now
            if d < cutoff { return false }
        }
        let q = f.query.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            let hay = [e.text, e.owner ?? "", e.noteTitle, e.account, e.project ?? "", e.dueText ?? ""].joined(separator: " ").lowercased()
            if !hay.contains(q) { return false }
        }
        return true
    }

    /// The entries that pass every filter, in display order within each group.
    static func apply(_ entries: [ActionEntry], _ f: ActionFilter, now: Date = Date(), calendar: Calendar = .current) -> [ActionEntry] {
        let today = calendar.startOfDay(for: now)
        return entries.filter {
            passes($0, f, now: now, calendar: calendar) && matches(f.status, bucket(of: $0, today: today, calendar: calendar))
        }
    }

    // MARK: Counts

    struct Counts: Equatable {
        var open = 0, overdue = 0, dueSoon = 0, noDate = 0, done = 0
        var all: Int { open + done }
        func count(_ s: ActionStatus) -> Int {
            switch s {
            case .open: return open; case .overdue: return overdue; case .dueSoon: return dueSoon
            case .noDate: return noDate; case .done: return done; case .all: return all
            }
        }
    }

    /// Per-status counts under every filter *except* the status, so each status
    /// choice shows how many items it would list.
    static func counts(_ entries: [ActionEntry], _ f: ActionFilter, now: Date = Date(), calendar: Calendar = .current) -> Counts {
        let today = calendar.startOfDay(for: now)
        var c = Counts()
        for e in entries where passes(e, f, now: now, calendar: calendar) {
            switch bucket(of: e, today: today, calendar: calendar) {
            case .done: c.done += 1
            case .overdue: c.open += 1; c.overdue += 1
            case .today, .thisWeek: c.open += 1; c.dueSoon += 1
            case .later: c.open += 1
            case .noDate: c.open += 1; c.noDate += 1
            }
        }
        return c
    }

    // MARK: Owners

    /// The distinct owners across `entries` (case-insensitive), most items first,
    /// for the owner menu. Display casing is the first one seen.
    static func owners(in entries: [ActionEntry]) -> [(name: String, count: Int)] {
        var byKey: [String: (name: String, count: Int)] = [:]
        for e in entries where !e.done {
            guard let o = e.owner, !o.isEmpty else { continue }
            let k = o.lowercased()
            byKey[k] = (byKey[k]?.name ?? o, (byKey[k]?.count ?? 0) + 1)
        }
        return byKey.values.sorted { ($0.count, $1.name.lowercased()) > ($1.count, $0.name.lowercased()) }
    }

    // MARK: Grouping

    struct Section: Identifiable, Equatable {
        let id: String
        let title: String
        var subtitle: String?
        var entries: [ActionEntry]
    }

    /// Display order within a section: open before done, soonest due first (undated
    /// last), then newest meeting, then text — so what needs doing first reads first.
    /// Order `entries` by `sort` (finished items always sink to the bottom; ties
    /// fall back to due date, meeting date, then name so the order is stable).
    static func sorted(_ entries: [ActionEntry], by sort: ActionSort = .due,
                       ascending: Bool = true) -> [ActionEntry] {
        func cmp<T: Comparable>(_ a: T, _ b: T) -> Int { a < b ? -1 : (a > b ? 1 : 0) }
        func text(_ a: String, _ b: String) -> Int {
            switch a.localizedCaseInsensitiveCompare(b) {
            case .orderedAscending: return -1
            case .orderedDescending: return 1
            case .orderedSame: return 0
            }
        }
        // Items missing the key (no due date, no owner…) always trail, in either direction.
        func key(_ a: ActionEntry, _ b: ActionEntry) -> (Int, Bool) {
            switch sort {
            case .due:
                switch (a.due, b.due) {
                case let (x?, y?): return (cmp(x, y), true)
                case (_?, nil): return (-1, false)
                case (nil, _?): return (1, false)
                case (nil, nil): return (0, true)
                }
            case .meeting:
                return (cmp(a.noteDate ?? .distantPast, b.noteDate ?? .distantPast), true)
            case .owner:
                switch (a.owner ?? "", b.owner ?? "") {
                case ("", ""): return (0, true)
                case ("", _): return (1, false)
                case (_, ""): return (-1, false)
                case let (x, y): return (text(x, y), true)
                }
            case .account:
                return (text(a.account, b.account), true)
            case .text:
                return (text(a.text, b.text), true)
            }
        }
        return entries.sorted { a, b in
            if a.done != b.done { return !a.done }
            let (k, directional) = key(a, b)
            if k != 0 { return directional ? (ascending ? k < 0 : k > 0) : k < 0 }
            let d = cmp(a.due ?? .distantFuture, b.due ?? .distantFuture)
            if d != 0 { return d < 0 }
            let m = cmp(a.noteDate ?? .distantPast, b.noteDate ?? .distantPast)
            if m != 0 { return m > 0 }
            return text(a.text, b.text) < 0
        }
    }

    static func group(_ entries: [ActionEntry], by grouping: ActionGrouping,
                      sort: ActionSort = .due, ascending: Bool = true,
                      now: Date = Date(), calendar: Calendar = .current) -> [Section] {
        func sorted(_ es: [ActionEntry]) -> [ActionEntry] { Self.sorted(es, by: sort, ascending: ascending) }
        let today = calendar.startOfDay(for: now)
        switch grouping {
        case .none:
            return entries.isEmpty ? [] : [Section(id: "all", title: "All items", subtitle: nil, entries: sorted(entries))]
        case .due:
            return ActionBucket.allCases.compactMap { b in
                let es = entries.filter { bucket(of: $0, today: today, calendar: calendar) == b }
                return es.isEmpty ? nil : Section(id: "due-\(b.rawValue)", title: b.title, subtitle: nil, entries: sorted(es))
            }
        case .owner:
            var order: [String] = [], byKey: [String: [ActionEntry]] = [:], names: [String: String] = [:]
            for e in entries {
                let name = (e.owner?.isEmpty == false) ? e.owner! : "Unassigned"
                let k = name.lowercased()
                if byKey[k] == nil { order.append(k); names[k] = name }
                byKey[k, default: []].append(e)
            }
            return order.sorted { a, b in
                if (a == "unassigned") != (b == "unassigned") { return b == "unassigned" }
                return names[a]!.localizedCaseInsensitiveCompare(names[b]!) == .orderedAscending
            }.map { Section(id: "owner-\($0)", title: names[$0]!, subtitle: nil, entries: sorted(byKey[$0]!)) }
        case .account:
            var order: [String] = [], byAccount: [String: [ActionEntry]] = [:]
            for e in entries {
                if byAccount[e.account] == nil { order.append(e.account) }
                byAccount[e.account, default: []].append(e)
            }
            return order.sorted { a, b in
                if (a == "Unfiled") != (b == "Unfiled") { return b == "Unfiled" }
                return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
            }.map { Section(id: "account-\($0)", title: $0, subtitle: nil, entries: sorted(byAccount[$0]!)) }
        case .meeting:
            var order: [String] = [], byNote: [String: [ActionEntry]] = [:]
            for e in entries {
                if byNote[e.noteKey] == nil { order.append(e.noteKey) }
                byNote[e.noteKey, default: []].append(e)
            }
            return order.sorted { (byNote[$0]![0].noteDate ?? .distantPast) > (byNote[$1]![0].noteDate ?? .distantPast) }
                .map { key in
                    let es = byNote[key]!
                    return Section(id: "note-\(key)", title: es[0].noteTitle,
                                   subtitle: es[0].noteDate.map { $0.formatted(date: .abbreviated, time: .omitted) },
                                   entries: sorted(es))
                }
        }
    }
}
