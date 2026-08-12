import Foundation

// MARK: - App Paths
//
// One home for the app's on-disk support/cache locations, so the
// `Application Support/GhostWriter` (and Caches) directory isn't recomputed —
// with a force-unwrap — in every persisted store.

enum AppPaths {
    /// `~/Library/Application Support/GhostWriter`, created if missing.
    /// Rebuildable data (model catalog, API usage log, AI cache) lives here.
    static func support(creating: Bool = true) -> URL {
        directory(in: .applicationSupportDirectory, creating: creating)
    }

    /// `~/Library/Caches/GhostWriter`, created if missing.
    static func caches(creating: Bool = true) -> URL {
        directory(in: .cachesDirectory, creating: creating)
    }

    private static func directory(in domain: FileManager.SearchPathDirectory, creating: Bool) -> URL {
        let base = FileManager.default.urls(for: domain, in: .userDomainMask)[0]
            .appendingPathComponent("GhostWriter", isDirectory: true)
        if creating { try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true) }
        return base
    }
}
