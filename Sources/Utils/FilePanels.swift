import AppKit
import UniformTypeIdentifiers

// MARK: - Save / open panel helpers
//
// The app saves exports (Markdown, PDF, JSON, ZIP) and imports files (JSON,
// ZIP) from many places, each previously repeating the same NSSavePanel /
// NSOpenPanel setup plus the "Saved/Exported <name>" / "…failed: <error>"
// status-string formatting. These two helpers are the single home for that.

enum FilePanels {

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
