import Foundation
import EventKit

// MARK: - Action Items → Apple Reminders
//
// Pushes open action items into the system Reminders app so they live alongside
// the user's other to-dos. Each reminder carries the action text, a note back to
// the source meeting, and a due date when the item had one. Requires the
// NSRemindersFullAccessUsageDescription string in Info.plist; access is requested
// lazily on first export.

enum RemindersExporter {

    enum ExportError: LocalizedError {
        case accessDenied
        case noDefaultList
        case underlying(Error)

        var errorDescription: String? {
            switch self {
            case .accessDenied:  return "Reminders access was denied. Enable it in System Settings → Privacy & Security → Reminders."
            case .noDefaultList: return "No Reminders list is available to add to."
            case .underlying(let e): return e.localizedDescription
            }
        }
    }

    /// Create a reminder per item in the default list. Returns the count saved.
    static func export(_ items: [NotesLibrary.ActionItem]) async throws -> Int {
        guard !items.isEmpty else { return 0 }
        let store = EKEventStore()
        try await requestAccess(store)

        guard let list = store.defaultCalendarForNewReminders() else {
            throw ExportError.noDefaultList
        }

        for item in items {
            let reminder = EKReminder(eventStore: store)
            reminder.calendar = list
            reminder.title = item.displayText
            reminder.notes = "From meeting: \(item.file.displayName)"
            if let due = item.due, let comps = dueComponents(from: due) {
                reminder.dueDateComponents = comps
            }
            do {
                try store.save(reminder, commit: false)
            } catch {
                throw ExportError.underlying(error)
            }
        }
        do {
            try store.commit()
        } catch {
            throw ExportError.underlying(error)
        }
        return items.count
    }

    /// Request Reminders access, spanning the macOS 14 full-access API and the
    /// older combined API.
    private static func requestAccess(_ store: EKEventStore) async throws {
        let granted: Bool
        if #available(macOS 14.0, *) {
            granted = (try? await store.requestFullAccessToReminders()) ?? false
        } else {
            granted = await withCheckedContinuation { cont in
                store.requestAccess(to: .reminder) { ok, _ in cont.resume(returning: ok) }
            }
        }
        if !granted { throw ExportError.accessDenied }
    }

    /// Parse a stated due date into date components. Accepts ISO "yyyy-MM-dd"
    /// (what the summary is asked to emit); anything else is left off the
    /// reminder rather than guessed wrong.
    private static func dueComponents(from text: String) -> DateComponents? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: text.trimmingCharacters(in: .whitespaces)) else {
            return nil
        }
        return Calendar.current.dateComponents([.year, .month, .day], from: date)
    }
}
