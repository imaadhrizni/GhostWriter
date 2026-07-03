import Foundation

// MARK: - Meeting Notes Writer
//
// Creates a timestamped markdown file in ~/Documents/Notes/ when a meeting starts
// and appends each transcribed segment as it arrives.

final class MeetingNotesWriter {

    private(set) var currentFilePath: URL?
    /// The most recently finished session's file (survives endSession).
    private(set) var lastCompletedFilePath: URL?

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

            var header = ""
            if AppSettings.shared.frontMatterEnabled {
                // Obsidian/Notion-friendly YAML front-matter
                let isoFormatter = ISO8601DateFormatter()
                header += """
                ---
                title: Meeting \(timestamp)
                date: \(isoFormatter.string(from: Date()))
                tags: [meeting, ghostwriter]
                ---

                """
            }
            header += "# Meeting Notes\n**\(displayDate)**\n\n---\n\n"
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
        lastCompletedFilePath = fileURL
        currentFilePath = nil
        Log.meeting.info("📝 Meeting notes saved")
    }

    /// Appends an AI-generated summary section to a finished notes file.
    func appendSummary(_ summary: String, to fileURL: URL) {
        append("\n# Summary\n\n\(summary)\n", to: fileURL)
        Log.meeting.info("📝 Summary appended")
    }

    /// Full text of a notes file (for summarization).
    func transcriptText(of fileURL: URL) -> String? {
        try? String(contentsOf: fileURL, encoding: .utf8)
    }

    // MARK: - Appending Transcripts

    /// Appends a transcribed segment with a timestamp and optional speaker label.
    /// `at` allows retried segments to carry their original capture time.
    func append(segment text: String, speaker: String = "Them", at date: Date = Date()) {
        guard let fileURL = currentFilePath else { return }

        let timestamp = Self.timeFormatter.string(from: date)

        // "You"/"Them" are role keys — map them to the user's custom labels
        // (falling back to defaults if a label was left empty in Settings).
        let settings = AppSettings.shared
        let you  = settings.speakerLabelYou.isEmpty  ? AppSettings.Default.speakerLabelYou  : settings.speakerLabelYou
        let them = settings.speakerLabelThem.isEmpty ? AppSettings.Default.speakerLabelThem : settings.speakerLabelThem
        // Diarization passes "Them 2", "Them 3", … — keep the numeric suffix
        // while still honoring the custom label.
        let speakerTag: String
        if speaker == "You" {
            speakerTag = "**\(you)**"
        } else {
            let suffix = speaker.hasPrefix("Them ") ? " \(speaker.dropFirst(5))" : ""
            speakerTag = "_\(them)\(suffix)_"
        }
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
