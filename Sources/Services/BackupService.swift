import Foundation

// MARK: - Backup / Restore
//
// One portable `.zip` snapshot of everything GhostWriter owns on disk:
// meeting notes, quick notes, dictations, and the Catalog (`Catalog.json`).
// The archive is a plain zip laid out as:
//
//   manifest.json      ← identifies the archive + which folders were external
//   Notes/             ← the meeting-notes folder (includes Catalog.json, and
//                         Quick Notes / Dictations too when they're nested here)
//   QuickNotes/        ← only when the quick-notes folder lives OUTSIDE Notes
//   Dictations/        ← only when the dictations folder lives OUTSIDE Notes
//
// Restore copies each captured folder back into the *currently configured*
// destination (merging, incoming files win), then the caller reloads the
// catalog and re-indexes. Zipping uses the system `zip`/`unzip` binaries so
// there's no third-party dependency.

enum BackupService {

    struct Manifest: Codable {
        var app = "GhostWriter"
        var formatVersion = 1
        var createdAt: Date
        var quickNotesExternal: Bool
        var dictationsExternal: Bool
    }

    struct RestoreSummary {
        var notes: Bool
        var quickNotes: Bool
        var dictations: Bool
    }

    enum BackupError: LocalizedError {
        case zipFailed(Int32)
        case unzipFailed(Int32)
        case notABackup

        var errorDescription: String? {
            switch self {
            case .zipFailed(let c):   return "Could not create the backup archive (zip exited \(c))."
            case .unzipFailed(let c): return "Could not read the backup archive (unzip exited \(c))."
            case .notABackup:         return "That file isn't a GhostWriter backup."
            }
        }
    }

    // MARK: Create

    /// Build a backup zip at `destination` (a `.zip` URL the user chose), from
    /// the folders currently configured in Settings.
    @MainActor
    static func createBackup(to destination: URL) throws {
        let s = AppSettings.shared
        try writeBackup(notesFolder: s.notesFolder,
                        quickNotesFolder: s.quickNotesFolder,
                        dictationsFolder: s.dictationsFolder,
                        to: destination)
    }

    /// Zip the given data folders into `destination`. Pure I/O with no
    /// `AppSettings` access, so it is safe to run off the main actor (the
    /// automatic backup snapshots the folder URLs on the main actor first, then
    /// calls this on a background queue to keep the UI responsive).
    static func writeBackup(notesFolder notes: URL, quickNotesFolder quick: URL,
                            dictationsFolder dict: URL, to destination: URL) throws {
        let fm = FileManager.default

        let staging = fm.temporaryDirectory.appendingPathComponent("GhostWriterBackup-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        if fm.fileExists(atPath: notes.path) {
            try fm.copyItem(at: notes, to: staging.appendingPathComponent("Notes"))
        }
        // Quick notes / dictations are captured separately only when they live
        // outside the notes folder — otherwise they're already inside Notes/.
        let quickExternal = !isInside(quick, notes)
        let dictExternal = !isInside(dict, notes)
        if quickExternal, fm.fileExists(atPath: quick.path) {
            try fm.copyItem(at: quick, to: staging.appendingPathComponent("QuickNotes"))
        }
        if dictExternal, fm.fileExists(atPath: dict.path) {
            try fm.copyItem(at: dict, to: staging.appendingPathComponent("Dictations"))
        }

        let manifest = Manifest(createdAt: Date(), quickNotesExternal: quickExternal, dictationsExternal: dictExternal)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: staging.appendingPathComponent("manifest.json"))

        try? fm.removeItem(at: destination)   // zip would otherwise update-in-place, leaving stale entries
        let code = run("/usr/bin/zip", ["-r", "-q", "-X", destination.path, "."], cwd: staging)
        guard code == 0 else { throw BackupError.zipFailed(code) }
    }

    // MARK: Automatic daily backup

    /// Posted on the main thread after an automatic backup finishes (whether it
    /// succeeded or failed) so the Settings readout can refresh.
    static let automaticBackupDidComplete = Notification.Name("BackupServiceAutomaticBackupDidComplete")

    /// Filename of the automatic archive for a given day, e.g.
    /// `GhostWriter-2026-07-28.zip`. Dating the name makes it one-per-day and
    /// idempotent — re-running the same day overwrites rather than piling up.
    static func automaticArchiveName(for date: Date) -> String {
        "GhostWriter-\(DateDisplay.posixDay.string(from: date)).zip"
    }

    /// Snapshot the configured folders on the main actor, then zip + prune on a
    /// background queue so a large notes folder never blocks the UI. On success
    /// records `lastAutomaticBackupAt`; either way posts
    /// `automaticBackupDidComplete`. The caller is responsible for the due-check
    /// and idle-gate (see the app's backup scheduler).
    @MainActor
    static func runAutomaticBackup() {
        let s = AppSettings.shared
        let notes = s.notesFolder, quick = s.quickNotesFolder, dict = s.dictationsFolder
        let folder = s.autoBackupFolder
        let retention = s.autoBackupRetentionDays
        let destination = folder.appendingPathComponent(automaticArchiveName(for: Date()))

        DispatchQueue.global(qos: .utility).async {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try writeBackup(notesFolder: notes, quickNotesFolder: quick, dictationsFolder: dict, to: destination)
                pruneAutomaticBackups(in: folder, keeping: retention)
                DispatchQueue.main.async {
                    AppSettings.shared.lastAutomaticBackupAt = Date()
                    Log.app.info("💾 Automatic backup written: \(destination.lastPathComponent, privacy: .public)")
                    NotificationCenter.default.post(name: automaticBackupDidComplete, object: nil)
                }
            } catch {
                DispatchQueue.main.async {
                    Log.app.error("💾 Automatic backup failed: \(error.localizedDescription, privacy: .public)")
                    if AppSettings.shared.errorNotifications {
                        NotificationManager.shared.notifyBackupFailed(error.localizedDescription)
                    }
                    NotificationCenter.default.post(name: automaticBackupDidComplete, object: nil)
                }
            }
        }
    }

    /// Keep only the newest `keep` dated auto-backup archives in `folder`,
    /// deleting the rest. Only ever touches files matching the
    /// `GhostWriter-YYYY-MM-DD.zip` pattern, so nothing else in the folder is at
    /// risk. The date in the name sorts lexically the same as chronologically.
    static func pruneAutomaticBackups(in folder: URL, keeping keep: Int) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        let archives = items
            .filter { isAutomaticArchive($0.lastPathComponent) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }   // newest (latest date) first
        guard archives.count > max(1, keep) else { return }
        for stale in archives.dropFirst(max(1, keep)) { try? fm.removeItem(at: stale) }
    }

    /// The dated auto-backup archives currently on disk, newest first — for the
    /// Settings readout ("N kept").
    static func automaticArchives(in folder: URL) -> [URL] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }
        return items.filter { isAutomaticArchive($0.lastPathComponent) }
                    .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// True for a `GhostWriter-YYYY-MM-DD.zip` filename (with a parseable date).
    private static func isAutomaticArchive(_ name: String) -> Bool {
        let prefix = "GhostWriter-", suffix = ".zip"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return false }
        let day = name.dropFirst(prefix.count).dropLast(suffix.count)
        return DateDisplay.posixDay.date(from: String(day)) != nil
    }

    // MARK: Restore

    /// Extract a backup and merge its folders into the current destinations.
    /// Returns which parts were present. Reloading the catalog is the caller's job.
    @MainActor
    static func restoreBackup(from archive: URL) throws -> RestoreSummary {
        let fm = FileManager.default
        let s = AppSettings.shared

        let temp = fm.temporaryDirectory.appendingPathComponent("GhostWriterRestore-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }

        let code = run("/usr/bin/unzip", ["-o", "-q", archive.path, "-d", temp.path])
        guard code == 0 else { throw BackupError.unzipFailed(code) }

        let notesSrc = temp.appendingPathComponent("Notes")
        let quickSrc = temp.appendingPathComponent("QuickNotes")
        let dictSrc  = temp.appendingPathComponent("Dictations")
        let hasManifest = fm.fileExists(atPath: temp.appendingPathComponent("manifest.json").path)
        guard hasManifest || fm.fileExists(atPath: notesSrc.path) else { throw BackupError.notABackup }

        var summary = RestoreSummary(notes: false, quickNotes: false, dictations: false)
        if fm.fileExists(atPath: notesSrc.path) {
            try mergeCopy(from: notesSrc, to: s.notesFolder); summary.notes = true
        }
        if fm.fileExists(atPath: quickSrc.path) {
            try mergeCopy(from: quickSrc, to: s.quickNotesFolder); summary.quickNotes = true
        }
        if fm.fileExists(atPath: dictSrc.path) {
            try mergeCopy(from: dictSrc, to: s.dictationsFolder); summary.dictations = true
        }
        return summary
    }

    // MARK: Helpers

    /// True when `child` is the same as, or nested under, `parent`.
    private static func isInside(_ child: URL, _ parent: URL) -> Bool {
        let c = child.standardizedFileURL.path, p = parent.standardizedFileURL.path
        return c == p || c.hasPrefix(p.hasSuffix("/") ? p : p + "/")
    }

    /// Recursively copy `src`'s contents into `dst`, creating directories and
    /// overwriting existing files (incoming wins).
    private static func mergeCopy(from src: URL, to dst: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)
        for item in try fm.contentsOfDirectory(at: src, includingPropertiesForKeys: [.isDirectoryKey]) {
            let target = dst.appendingPathComponent(item.lastPathComponent)
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir {
                try mergeCopy(from: item, to: target)
            } else {
                if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                try fm.copyItem(at: item, to: target)
            }
        }
    }

    /// Run a system tool synchronously, returning its exit code.
    private static func run(_ launchPath: String, _ args: [String], cwd: URL? = nil) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}
