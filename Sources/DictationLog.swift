import Foundation
import Combine

// MARK: - Dictation Log
//
// A persisted, capped record of recent dictations — which app (and browser
// host), which writing style, duration, and word count. Powers the "Recent
// Dictations" view in Settings so you can see what style each dictation used
// and tune your per-app / domain rules. Separate from the in-memory
// Recent-Dictations menu (which keeps the polished text for re-copy).

final class DictationLog: ObservableObject {

    static let shared = DictationLog()

    struct Entry: Codable, Identifiable {
        var id = UUID()
        let date: Date
        let app: String     // app name, plus host for browsers ("Chrome · gmail.com")
        let style: String   // resolved writing-style name
        let seconds: Int
        let words: Int
    }

    @Published private(set) var entries: [Entry] = []

    private let key = "dictation.log"
    private let limit = 100
    private let defaults = UserDefaults.standard

    private init() {
        if let data = defaults.data(forKey: key),
           let list = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = list
        }
    }

    func record(app: String, style: String, seconds: Int, words: Int) {
        let entry = Entry(date: Date(), app: app, style: style, seconds: seconds, words: words)
        DispatchQueue.main.async {
            self.entries.insert(entry, at: 0)
            if self.entries.count > self.limit {
                self.entries.removeLast(self.entries.count - self.limit)
            }
            self.persist()
        }
    }

    func clear() {
        entries.removeAll()
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: key)
        }
    }
}
