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
    @Published var targetKind = ""   // "", "org", or "project"
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
    var failedCount: Int { items.filter { $0.status == .failed }.count }

    /// Reset a failed item back to the queue so the next run retries it.
    func retry(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }), items[i].status == .failed else { return }
        items[i].status = .queued
        items[i].error = nil
        items[i].noteURL = nil
    }

    /// Requeue every failed item for a one-click retry-all.
    func retryFailed() {
        for i in items.indices where items[i].status == .failed {
            items[i].status = .queued
            items[i].error = nil
            items[i].noteURL = nil
        }
    }

    /// Re-transcribe a retained recording into a **fresh** note, filed under the
    /// same org/project as `sourceNote`, and point the new note back at the same
    /// recording. Used by the Catalog's "Regenerate from audio" recovery when a
    /// meeting's original transcription/summary failed. Returns the new note URL.
    func regenerate(fromAudio url: URL, like sourceNote: CatalogNote) async -> URL? {
        let prevKind = targetKind, prevID = targetID
        if let pid = sourceNote.projectIDs.first { targetKind = "project"; targetID = pid }
        else if let oid = sourceNote.orgIDs.first { targetKind = "org"; targetID = oid }
        else { targetKind = ""; targetID = "" }
        defer { targetKind = prevKind; targetID = prevID }
        do {
            let newURL = try await importOne(url)
            MeetingNotesWriter.setAudioPath(settings.relativePath(of: url), to: newURL)
            return newURL
        } catch {
            Log.meeting.error("🎙️ Regenerate from audio failed: \(error.localizedDescription)")
            return nil
        }
    }

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

        let rel = settings.relativePath(of: fileURL)
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
        let wantsOpenQuestions = settings.extractUnanswered
        if wantsSummary || wantsActions || wantsStructured || wantsOpenQuestions,
           let raw = try? await polisher.summarize(
               transcript: transcript, template: template,
               includeSummary: wantsSummary, includeActionItems: wantsActions,
               includeStructured: wantsStructured, includeOpenQuestions: wantsOpenQuestions),
           let clean = MeetingNotesWriter.sanitizedSummary(raw) {
            writer.appendSummary(clean, to: fileURL)
        }
        if settings.topicChapters,
           let ch = try? await polisher.chapters(transcript: transcript), !ch.isEmpty {
            writer.appendChapters(ch, to: fileURL)
        }
    }

    private func transcribe(_ url: URL, mime: String, seconds: Double) async throws -> String {
        if settings.localOnlyMode {
            let pcm = try AudioFileImporter.decodePCM16k(from: url)
            return Redactor.redact(try await offline.transcribe(audioData: pcm))
        }

        // Cloud path. When we can decode the file, normalize it to a compact,
        // Whisper-optimal 16 kHz-mono upload (Opus → FLAC → WAV) and chunk it if
        // it would exceed Groq's request limit — smaller uploads, and the
        // "unsupported container" failure class disappears because we control
        // what's sent. Containers Core Audio can't read (ogg/opus/webm) can't be
        // decoded, so those upload as-is.
        if let pcm = try? AudioFileImporter.decodePCM16k(from: url) {
            do {
                return Redactor.redact(try await cloudTranscribe(pcm16k: pcm))
            } catch let cloudError {
                guard settings.offlineFallback else { throw cloudError }
                do {
                    return Redactor.redact(try await offline.transcribe(audioData: pcm))
                } catch {
                    throw AudioFileImporter.ImportError.transcriptionFailed(
                        primary: cloudError.localizedDescription,
                        fallback: error.localizedDescription)
                }
            }
        }

        // Undecodable container → the original bytes are the only cloud option.
        return Redactor.redact(try await groq.transcribe(fileURL: url, mimeType: mime, audioSeconds: seconds))
    }

    /// Transcribe decoded 16 kHz PCM via Groq: compress to the smallest accepted
    /// format and, if the whole clip would exceed Groq's per-request limit, split
    /// it on silence and stitch the pieces. Throws if every attempt fails.
    private func cloudTranscribe(pcm16k: Data) async throws -> String {
        let totalSeconds = Double(pcm16k.count) / Double(AudioTranscoder.bytesPerSecond)

        // 1) Whole clip — upload the first candidate that fits and Groq accepts.
        let whole = AudioTranscoder.uploadCandidates(pcm16k: pcm16k)
        defer { AudioTranscoder.cleanUp(whole) }
        if let text = try await uploadFirstAccepted(whole, seconds: totalSeconds, source: "Audio import") {
            return text
        }

        // 2) Too large — size the chunk length from the smallest encoding's
        //    bitrate so each piece fits, split on silence, and transcribe each.
        let smallest = whole.map(\.bytes).min() ?? pcm16k.count
        let pieces = max(2, Int((Double(smallest) / Double(GroqService.uploadLimitBytes)).rounded(.up)) + 1)
        let chunkSeconds = max(30, totalSeconds / Double(pieces))
        let chunks = AudioTranscoder.splitOnSilence(pcm16k: pcm16k, maxSeconds: chunkSeconds)
        guard chunks.count > 1 else { throw AudioFileImporter.ImportError.emptyTranscript }

        var parts: [String] = []
        for (i, chunk) in chunks.enumerated() {
            let candidates = AudioTranscoder.uploadCandidates(pcm16k: chunk)
            defer { AudioTranscoder.cleanUp(candidates) }
            let secs = Double(chunk.count) / Double(AudioTranscoder.bytesPerSecond)
            guard let text = try await uploadFirstAccepted(
                candidates, seconds: secs,
                source: "Audio import (chunk \(i + 1)/\(chunks.count))") else {
                throw AudioFileImporter.ImportError.emptyTranscript
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { parts.append(trimmed) }
        }
        return parts.joined(separator: " ")
    }

    /// Upload candidates in order (smallest first), skipping any over Groq's
    /// size limit, and return the first transcript Groq accepts. Returns nil
    /// when nothing fits (the caller then chunks); throws when something fit but
    /// every fitting upload failed.
    private func uploadFirstAccepted(_ candidates: [AudioTranscoder.Encoded],
                                     seconds: Double, source: String) async throws -> String? {
        var lastError: Error?
        var anyFit = false
        for c in candidates where c.bytes <= GroqService.uploadLimitBytes {
            anyFit = true
            do {
                return try await groq.transcribe(fileURL: c.url, mimeType: c.mime,
                                                 audioSeconds: seconds, source: source)
            } catch {
                lastError = error
                Log.api.warning("⚠️ Groq rejected \(c.mime) upload (\(error.localizedDescription)) — trying next candidate")
            }
        }
        if anyFit, let lastError { throw lastError }
        return nil
    }
}
