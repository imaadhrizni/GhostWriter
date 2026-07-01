import Foundation

// MARK: - Meeting Notes Writer
//
// Creates a timestamped markdown file in ~/Documents/Notes/ when a meeting starts
// and appends each transcribed segment as it arrives.

final class MeetingNotesWriter {

    private(set) var currentFilePath: URL?
    private let notesDirectory: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        notesDirectory = docs.appendingPathComponent("Notes", isDirectory: true)
    }

    // MARK: - Session Lifecycle

    /// Call when meeting mode starts. Creates the notes file and writes the header.
    func beginSession() {
        do {
            try FileManager.default.createDirectory(at: notesDirectory, withIntermediateDirectories: true)

            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            let timestamp = formatter.string(from: Date())
            let fileName = "Meeting_\(timestamp).md"
            let fileURL = notesDirectory.appendingPathComponent(fileName)

            let displayFormatter = DateFormatter()
            displayFormatter.dateStyle = .long
            displayFormatter.timeStyle = .short
            let displayDate = displayFormatter.string(from: Date())

            let header = "# Meeting Notes\n**\(displayDate)**\n\n---\n\n"
            try header.write(to: fileURL, atomically: true, encoding: .utf8)

            currentFilePath = fileURL
            print("📝 Meeting notes → \(fileURL.path)")
        } catch {
            print("❌ Could not create meeting notes file: \(error.localizedDescription)")
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
        print("📝 Meeting notes saved")
    }

    // MARK: - Appending Transcripts

    /// Appends a transcribed segment with a timestamp and optional speaker label.
    func append(segment text: String, speaker: String = "Them") {
        guard let fileURL = currentFilePath else { return }

        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm:ss"
        let timestamp = timeFormatter.string(from: Date())

        let speakerTag = speaker == "You" ? "**You**" : "_Them_"
        let line = "**[\(timestamp)]** \(speakerTag): \(text)\n\n"
        append(line, to: fileURL)
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
