import Foundation

// MARK: - Meeting Notes Writer
//
// Creates a timestamped markdown file in ~/Documents/Notes/ when a meeting starts
// and appends each transcribed segment as it arrives.

final class MeetingNotesWriter {

    private(set) var currentFilePath: URL?

    /// Read live from settings so a folder change applies to the next session.
    private var notesDirectory: URL { AppSettings.shared.notesFolder }

    // Formatters are expensive to create — build once. This class is only used
    // from the transcription Tasks one line at a time, so this is safe.
    private static let fileNameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f
    }()
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    // MARK: - Session Lifecycle

    /// Call when meeting mode starts. Creates the notes file and writes the header.
    func beginSession() {
        do {
            try FileManager.default.createDirectory(at: notesDirectory, withIntermediateDirectories: true)

            let timestamp = Self.fileNameFormatter.string(from: Date())
            let fileName = "Meeting_\(timestamp).md"
            let fileURL = notesDirectory.appendingPathComponent(fileName)

            let displayFormatter = DateFormatter()
            displayFormatter.dateStyle = .long
            displayFormatter.timeStyle = .short
            let displayDate = displayFormatter.string(from: Date())

            let header = "# Meeting Notes\n**\(displayDate)**\n\n---\n\n"
            try header.write(to: fileURL, atomically: true, encoding: .utf8)

            currentFilePath = fileURL
            Log.meeting.info("📝 Meeting notes → \(fileURL.path)")
        } catch {
            Log.meeting.error("❌ Could not create meeting notes file: \(error.localizedDescription)")
        }
    }

    /// Call when meeting mode stops. Writes a footer with duration.
    func endSession(startedAt: Date) {
        guard let fileURL = currentFilePath else { return }

        let elapsed = Int(Date().timeIntervalSince(startedAt))
        let duration = String(format: "%d:%02d", elapsed / 60, elapsed % 60)
        let footer = "\n---\n*Meeting duration: \(duration)*\n"

        append(footer, to: fileURL)
        currentFilePath = nil
        Log.meeting.info("📝 Meeting notes saved")
    }

    // MARK: - Appending Transcripts

    /// Appends a transcribed segment with a timestamp and optional speaker label.
    func append(segment text: String, speaker: String = "Them") {
        guard let fileURL = currentFilePath else { return }

        let timestamp = Self.timeFormatter.string(from: Date())

        // "You"/"Them" are role keys — map them to the user's custom labels
        // (falling back to defaults if a label was left empty in Settings).
        let settings = AppSettings.shared
        let you  = settings.speakerLabelYou.isEmpty  ? AppSettings.Default.speakerLabelYou  : settings.speakerLabelYou
        let them = settings.speakerLabelThem.isEmpty ? AppSettings.Default.speakerLabelThem : settings.speakerLabelThem
        let speakerTag = speaker == "You" ? "**\(you)**" : "_\(them)_"
        let line = "**[\(timestamp)]** \(speakerTag): \(text)\n\n"
        append(line, to: fileURL)
    }

    /// Appends an italic event marker (e.g. "Transcription paused") with a timestamp.
    func appendMarker(_ text: String) {
        guard let fileURL = currentFilePath else { return }
        let timestamp = Self.timeFormatter.string(from: Date())
        append("*[\(timestamp)] — \(text)*\n\n", to: fileURL)
    }

    // MARK: - Private

    private func append(_ text: String, to url: URL) {
        guard let data = text.data(using: .utf8),
              let handle = try? FileHandle(forWritingTo: url) else { return }
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    }
}
