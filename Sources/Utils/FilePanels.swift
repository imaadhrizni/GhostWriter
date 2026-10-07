import AppKit
import UniformTypeIdentifiers

// MARK: - Save / open panel helpers
//
// The app saves exports (Markdown, PDF, JSON, ZIP) and imports files (JSON,
// ZIP) from many places, each previously repeating the same NSSavePanel /
// NSOpenPanel setup plus the "Saved/Exported <name>" / "…failed: <error>"
// status-string formatting. These two helpers are the single home for that.

enum FilePanels {

    /// A title made safe to use as a file name: path/reserved characters become
    /// hyphens, whitespace is collapsed, and it's capped at 100 characters.
    /// Returns nil when nothing usable is left, so the caller keeps its fallback.
    static func fileSafeName(_ title: String) -> String? {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.controlCharacters)
        let cleaned = title.unicodeScalars.map { bad.contains($0) ? "-" : String($0) }.joined()
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". -"))
        let capped = String(cleaned.prefix(100)).trimmingCharacters(in: CharacterSet(charactersIn: ". -"))
        return capped.isEmpty ? nil : capped
    }

    /// Run a save panel and, on confirmation, hand the chosen URL to `write`.
    /// Returns a user-facing status string ("<successVerb> <file>" on success,
    /// "<failVerb> failed: …" on error), or nil when the user cancels.
    /// `directory` defaults to the notes folder.
    @discardableResult
    static func save(defaultName: String,
                     contentTypes: [UTType],
                     directory: URL = AppSettings.shared.notesFolder,
                     prompt: String? = nil,
                     successVerb: String = "Saved",
                     failVerb: String = "Save",
                     write: (URL) throws -> Void) -> String? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = contentTypes
        panel.nameFieldStringValue = defaultName
        panel.directoryURL = directory
        if let prompt { panel.prompt = prompt }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            try write(url)
            return "\(successVerb) \(url.lastPathComponent)"
        } catch {
            return "\(failVerb) failed: \(error.localizedDescription)"
        }
    }

    /// Run an open panel for a single file and return the chosen URL, or nil on
    /// cancel.
    static func openFile(contentTypes: [UTType],
                         directory: URL = AppSettings.shared.notesFolder,
                         prompt: String? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = contentTypes
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = directory
        if let prompt { panel.prompt = prompt }
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// Run an open panel for a single folder and return the chosen URL, or nil
    /// on cancel.
    static func openFolder(directory: URL = AppSettings.shared.notesFolder,
                           prompt: String? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = directory
        if let prompt { panel.prompt = prompt }
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
