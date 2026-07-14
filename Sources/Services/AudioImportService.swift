import Foundation
import AppKit

// MARK: - Audio Import Service
//
// Backs the Import Audio window. Holds the queue of files, transcribes each one
// (Groq file upload, on-device fallback), writes it as a meeting note dated to
// the file's own metadata, and links it into the Catalog under an optional
// org/opportunity chosen in the window. Observable so the window shows live
// per-file progress.

@MainActor
final class AudioImportService: ObservableObject {
    static let shared = AudioImportService()

    enum Status: Equatable { case queued, working, done, failed }

    struct Item: Identifiable {
        let id = UUID()
        let url: URL
        var status: Status = .queued
        var noteURL: URL?
        var error: String?
        var name: String { url.deletingPathExtension().lastPathComponent }
    }

    @Published var items: [Item] = []
    @Published var isRunning = false
    /// Batch assignment applied to every note created this run.
    @Published var targetKind = ""   // "", "org", or "opp"
    @Published var targetID = ""

    private let groq = GroqService()
    private let offline = OfflineTranscriber()
    private var settings: AppSettings { .shared }

    // Whisper's stock hallucinations on near-silent audio — dropped so an empty
    // clip doesn't produce a note that just says "you".
    private let hallucinations: Set<String> = [
        "thank you.", "thanks for watching.", "you", ".", "[music]", "[silence]", "..."
    ]

    // MARK: Queue

    func add(_ urls: [URL]) {
        let existing = Set(items.map { $0.url })
        for u in urls where AudioFileImporter.isAccepted(u) && !existing.contains(u) {
            items.append(Item(url: u))
        }
    }
    func remove(_ id: UUID) { items.removeAll { $0.id == id && $0.status != .working } }
    func clearFinished() { items.removeAll { $0.status == .done } }
    var queuedCount: Int { items.filter { $0.status == .queued }.count }

    // MARK: Run

    func run() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        let maxBytes = settings.audioImportMaxMB * 1_000_000
        var firstNote: URL?
        var done = 0

        for idx in items.indices where items[idx].status == .queued {
            items[idx].status = .working
            let url = items[idx].url
            do {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if size > maxBytes {
                    throw AudioFileImporter.ImportError.tooLarge(mb: size / 1_000_000, limit: settings.audioImportMaxMB)
                }
                let note = try await importOne(url)
                items[idx].noteURL = note
                items[idx].status = .done
                if firstNote == nil { firstNote = note }
                done += 1
            } catch {
                items[idx].error = error.localizedDescription
                items[idx].status = .failed
            }
        }

        if done > 0, let firstNote {
            NotificationManager.shared.notifyAudioImported(count: done, fileURL: firstNote)
        }
    }

    private func importOne(_ url: URL) async throws -> URL {
        let mime = AudioFileImporter.mimeType(for: url)
        let meta = await AudioFileImporter.metadata(of: url)
        let raw = try await transcribe(url, mime: mime, seconds: meta.duration ?? 0)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !hallucinations.contains(trimmed.lowercased()) else {
            throw AudioFileImporter.ImportError.emptyTranscript
        }

        // A content-derived title beats the raw filename. Cheap; skipped when
        // there's no cloud path (local-only / no key) — then we use the filename.
        let fallback = url.deletingPathExtension().lastPathComponent
        var title = fallback
        if !settings.localOnlyMode, KeychainService.groqAPIKey() != nil,
           let t = try? await TextPolisher().meetingTitle(transcript: trimmed),
           !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            title = t.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let fileURL = MeetingNotesWriter.importAudioNote(
            transcript: trimmed, recordedAt: meta.date, sourceFilename: fallback,
            duration: meta.duration, title: title) else {
            throw AudioFileImporter.ImportError.decodeFailed
        }

        // Same AI enrichment a live meeting gets (summary, action items,
        // structured extraction, unanswered questions, chapters) — gated by the
        // same settings, cloud-only. Best-effort: a failure leaves the raw
        // transcript intact.
        await enrich(fileURL: fileURL, transcript: trimmed)

        let root = settings.notesFolder.path + "/"
        let rel = fileURL.path.replacingOccurrences(of: root, with: "")
        let note = CatalogStore.shared.note(forRelativePath: rel, title: title, date: meta.date)
        if targetKind == "project", !targetID.isEmpty {
            CatalogStore.shared.setProject(targetID, on: note.id, true)
        } else if targetKind == "org", !targetID.isEmpty {
            CatalogStore.shared.setOrg(targetID, on: note.id, true)
        }
        return fileURL
    }

    /// Append the meeting-style AI sections to a freshly-written import. Uses the
    /// General template (imports have no chosen meeting type). Cloud-only; a
    /// no-op in local-only mode or without a key.
    private func enrich(fileURL: URL, transcript: String) async {
        guard !settings.localOnlyMode, KeychainService.groqAPIKey() != nil else { return }
        let polisher = TextPolisher()
        let writer = MeetingNotesWriter()
        let template = AppSettings.shared.template(withID: "general") ?? .builtIn(.general)

        let wantsSummary = settings.summariesEnabled
        let wantsActions = settings.actionItemsEnabled
        let wantsStructured = settings.structuredExtraction
        if wantsSummary || wantsActions || wantsStructured,
           let raw = try? await polisher.summarize(
               transcript: transcript, template: template,
               includeSummary: wantsSummary, includeActionItems: wantsActions,
               includeStructured: wantsStructured),
           let clean = Self.sanitizedSummary(raw) {
            writer.appendSummary(clean, to: fileURL)
        }
        if settings.extractUnanswered,
           let qs = try? await polisher.unansweredQuestions(transcript: transcript), !qs.isEmpty {
            writer.appendUnansweredQuestions(qs, to: fileURL)
        }
        if settings.topicChapters,
           let ch = try? await polisher.chapters(transcript: transcript), !ch.isEmpty {
            writer.appendChapters(ch, to: fileURL)
        }
    }

    /// Light guard mirroring the live path: drop an empty or explicitly-thin
    /// summary; otherwise keep the model's Markdown as-is.
    private static func sanitizedSummary(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "NOT_ENOUGH_CONTENT" else { return nil }
        return trimmed
    }

    private func transcribe(_ url: URL, mime: String, seconds: Double) async throws -> String {
        let text: String
        if settings.localOnlyMode {
            let pcm = try AudioFileImporter.decodePCM16k(from: url)
            text = try await offline.transcribe(audioData: pcm)
        } else {
            do {
                text = try await groq.transcribe(fileURL: url, mimeType: mime, audioSeconds: seconds)
            } catch {
                guard settings.offlineFallback, let pcm = try? AudioFileImporter.decodePCM16k(from: url) else { throw error }
                Log.api.warning("⚠️ Groq file transcription failed (\(error.localizedDescription)) — trying on-device")
                text = try await offline.transcribe(audioData: pcm)
            }
        }
        return Redactor.redact(text)
    }
}
