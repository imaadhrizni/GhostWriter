import Foundation
import Combine

// MARK: - Diagnostics Log
//
// A small in-memory ring buffer of recent surfaced errors, shown in the
// Diagnostics settings pane. Not persisted — it's a "what just went wrong?"
// aid, not an audit trail. os.Logger remains the durable record.

final class DiagnosticsLog: ObservableObject {

    static let shared = DiagnosticsLog()

    struct Entry: Identifiable {
        let id = UUID()
        let date: Date
        let message: String
    }

    @Published private(set) var entries: [Entry] = []

    private let limit = 50
    private init() {}

    func record(_ message: String) {
        let entry = Entry(date: Date(), message: message)
        DispatchQueue.main.async {
            self.entries.insert(entry, at: 0)
            if self.entries.count > self.limit {
                self.entries.removeLast(self.entries.count - self.limit)
            }
        }
    }

    func clear() {
        entries.removeAll()
    }
}
