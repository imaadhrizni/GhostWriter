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
        var error: String?
        /// This file was already transcribed before (matched an existing import
        /// note by name + size). Excluded from the run by default — so a re-select
        /// after relaunch doesn't silently re-bill — until "Transcribe anyway".
        var duplicate = false
        /// The matching prior import note, and whether it still shows in History
        /// (vs. was cleared) — drives the row's "Add to History" / "Show in
        /// History" affordance. Set alongside `duplicate`.
        var duplicateNoteID: String?
        var duplicateInHistory = false
        var name: String { url.deletingPathExtension().lastPathComponent }

        // Recording date and length from the file's own metadata, loaded when the
        // file is added (used to order a series by date).
        var partDate: Date?
        var partDuration: TimeInterval?
        /// Combine mode: this part's transcript once it succeeds ("" = no speech),
        /// kept so a retry after a *sibling* part fails doesn't re-transcribe —
        /// and re-bill — the parts that already worked.
        var partTranscript: String?
        var partBytes: Int?

        /// 0…1 through this file's own pipeline (read → transcribe → title → save →
        /// summarize → file), and a short description of the step it's on.
        var progress: Double = 0
        var stage = ""
    }

    /// The outcome of the most recent `run()`, for the window's completion
    /// banner. Reset when a new run starts; cleared by the UI when dismissed.
    struct RunSummary: Equatable { let done: Int; let failed: Int }

    @Published var items: [Item] = []
    @Published var isRunning = false
    @Published var lastRun: RunSummary?
    /// Batch assignment applied to every note created this run.
    @Published var targetKind = ""   // "", "org", or "project"
    @Published var targetID = ""
    /// Treat the queued files as consecutive parts of ONE recording and write a
    /// single note, instead of one note per file. Per-batch, deliberately not a
    /// persisted setting: whether a batch is one meeting has no sensible default.
    @Published var combineIntoOneNote = false
    /// How the parts are ordered when combining.
    @Published var partOrder: PartOrder = .fileName

    // MARK: Progress

    /// The files taking part in the current run — finished ones leave the queue
    /// but still count toward the overall bar until the run ends.
    private var runIDs: Set<UUID> = []
    /// Whether the current run is building one combined note.
    @Published private(set) var combiningRun = false

    /// Overall progress of the current run, 0…1, weighted by audio length so a
    /// 40-minute file moves the bar more than a 10-second clip (a file of unknown
    /// length counts as a minute). A finished or failed file counts as complete.
    var overallProgress: Double {
        let run = items.filter { runIDs.contains($0.id) }
        guard !run.isEmpty else { return 0 }
        let weights = run.map { max($0.partDuration ?? 60, 1) }
        let done = zip(run, weights).reduce(0.0) { sum, pair in
            let finished = pair.0.status == .done || pair.0.status == .failed
            return sum + (finished ? 1 : pair.0.progress) * pair.1
        }
        return min(1, done / weights.reduce(0, +))
    }

    /// "Transcribing file 3 of 10" / "Transcribing recording 4 of 10" / "Building
    /// the combined note" — where the run is, in words.
    var runLabel: String {
        let run = items.filter { runIDs.contains($0.id) }
        guard !run.isEmpty else { return "Working…" }
        if combiningRun {
            let transcribed = run.filter { $0.partTranscript != nil }.count
            return transcribed < run.count
                ? "Transcribing recording \(transcribed + 1) of \(run.count)"
                : "Building the combined note"
        }
        let finished = run.filter { $0.status == .done || $0.status == .failed }.count
        return "Transcribing file \(min(finished + 1, run.count)) of \(run.count)"
    }

    /// The step the file currently being worked on is at ("Summarizing…").
    var activeStage: String? {
        items.first { $0.status == .working && !$0.stage.isEmpty }?.stage
    }

    /// Record progress for `ids` (the file(s) the current step applies to).
    private func report(_ progress: Double, _ stage: String, for ids: [UUID]) {
        for id in ids {
            guard let i = items.firstIndex(where: { $0.id == id }) else { continue }
            items[i].progress = progress
            items[i].stage = stage
        }
    }

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
            var item = Item(url: u)
            // Flag files already transcribed in a prior session so we don't
            // silently re-transcribe (and re-bill) them; the user can still
            // override per-row with "Transcribe anyway" — or, when the prior note
            // was cleared from History, cheaply "Add to History" instead.
            let bytes = (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if let match = CatalogStore.shared.existingImport(filename: u.lastPathComponent, bytes: bytes) {
                item.duplicate = true
                item.duplicateNoteID = match.note.id
                item.duplicateInHistory = match.inHistory
            }
            items.append(item)
            let id = item.id
            Task { await self.loadMetadata(id: id, url: u) }
        }
    }

    /// Fill a freshly-added item's recording date and length (async — reads the asset).
    private func loadMetadata(id: UUID, url: URL) async {
        let meta = await AudioFileImporter.metadata(of: url)
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].partDate = meta.date
        items[i].partDuration = meta.duration
    }

    // MARK: Series ordering

    /// Indices of the files that will run, in series order.
    private func orderedGroup() -> [Int] {
        let eligible = items.indices.filter { items[$0].status == .queued && !items[$0].duplicate }
        return ImportSeries.ordered(eligible, by: partOrder,
                                    name: { items[$0].url.lastPathComponent },
                                    date: { items[$0].partDate })
    }

    /// Whether the next run will combine the queue into one note.
    var willCombine: Bool { combineIntoOneNote && queuedCount >= 2 }

    /// This file's 1-based position in the series (nil when not combining).
    func partNumber(for id: UUID) -> Int? {
        guard willCombine,
              let pos = orderedGroup().firstIndex(where: { items[$0].id == id }) else { return nil }
        return pos + 1
    }

    /// Drag-reorder in the queue list. Moving a row switches to manual ordering.
    func moveQueue(from source: IndexSet, to destination: Int) {
        let slots = items.indices.filter { items[$0].status != .done }
        var visible = slots.map { items[$0] }
        let moving = source.sorted().map { visible[$0] }
        for i in source.sorted().reversed() { visible.remove(at: i) }
        visible.insert(contentsOf: moving, at: destination - source.filter { $0 < destination }.count)
        for (slot, item) in zip(slots, visible) { items[slot] = item }
        partOrder = .manual
    }

    func remove(_ id: UUID) { items.removeAll { $0.id == id && $0.status != .working } }

    /// Clear the duplicate flag so a knowingly re-imported file transcribes.
    func transcribeAnyway(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].duplicate = false
    }

    /// Queued files that will actually run — duplicates are held back until the
    /// user opts in, so they don't inflate the count or the Transcribe button.
    var queuedCount: Int { items.filter { $0.status == .queued && !$0.duplicate }.count }
    var failedCount: Int { items.filter { $0.status == .failed }.count }

    /// Reset a failed item back to the queue so the next run retries it.
    func retry(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }), items[i].status == .failed else { return }
        items[i].status = .queued
        items[i].error = nil
        items[i].progress = 0
        items[i].stage = ""
    }

    /// Requeue every failed item for a one-click retry-all.
    func retryFailed() {
        for i in items.indices where items[i].status == .failed {
            items[i].status = .queued
            items[i].error = nil
            items[i].progress = 0
            items[i].stage = ""
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
        lastRun = nil            // a fresh batch supersedes the previous summary
        runIDs = Set(items.filter { $0.status == .queued && !$0.duplicate }.map(\.id))
        combiningRun = combineIntoOneNote && runIDs.count >= 2
        defer { isRunning = false; runIDs = []; combiningRun = false }

        let maxBytes = settings.audioImportMaxMB * 1_000_000

        if combineIntoOneNote, orderedGroup().count >= 2 {
            await runCombined(maxBytes: maxBytes)
            return
        }

        var firstNote: URL?
        var done = 0
        var failed = 0

        for idx in items.indices where items[idx].status == .queued && !items[idx].duplicate {
            items[idx].status = .working
            let url = items[idx].url
            do {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if size > maxBytes {
                    throw AudioFileImporter.ImportError.tooLarge(mb: size / 1_000_000, limit: settings.audioImportMaxMB)
                }
                let note = try await importOne(url, itemID: items[idx].id)
                items[idx].progress = 1
                items[idx].status = .done
                if firstNote == nil { firstNote = note }
                done += 1
            } catch {
                items[idx].error = error.localizedDescription
                items[idx].status = .failed
                failed += 1
            }
        }

        lastRun = RunSummary(done: done, failed: failed)
        if done > 0, let firstNote {
            NotificationManager.shared.notifyAudioImported(count: done, fileURL: firstNote)
        }
    }

    private func importOne(_ url: URL, itemID: UUID? = nil) async throws -> URL {
        let ids = itemID.map { [$0] } ?? []
        func step(_ progress: Double, _ stage: String) { report(progress, stage, for: ids) }

        step(0.03, "Reading audio…")
        let mime = AudioFileImporter.mimeType(for: url)
        let meta = await AudioFileImporter.metadata(of: url)
        step(0.08, "Transcribing…")
        let raw = try await transcribe(url, mime: mime, seconds: meta.duration ?? 0) { fraction, label in
            step(0.08 + 0.52 * fraction, label)
        }
        let spoken = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty, !hallucinations.contains(spoken.lowercased()) else {
            throw AudioFileImporter.ImportError.emptyTranscript
        }
        // Whisper returns one unbroken block — break it into readable paragraphs
        // (blank lines only; every word is kept).
        let trimmed = TranscriptFormatter.paragraphs(spoken)

        // A content-derived title beats the raw filename. Cheap; skipped when
        // there's no cloud path (local-only / no key) — then we use the filename.
        step(0.62, "Writing a title…")
        let fallback = url.deletingPathExtension().lastPathComponent
        var title = fallback
        if !settings.localOnlyMode, KeychainService.groqAPIKey() != nil,
           let t = try? await TextPolisher().meetingTitle(transcript: trimmed),
           !TranscriptFormatter.cleanTitle(t).isEmpty {
            title = TranscriptFormatter.cleanTitle(t)
        }

        step(0.70, "Saving the note…")
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        guard let fileURL = MeetingNotesWriter.importAudioNote(
            transcript: trimmed, recordedAt: meta.date, sourceFilename: url.lastPathComponent,
            duration: meta.duration, sourceBytes: bytes, title: title) else {
            throw AudioFileImporter.ImportError.decodeFailed
        }

        // Link the note back to its audio, exactly as the live-recording path
        // does. `gw_source_file` above records only the original filename (for
        // duplicate detection); the *playable* link is `gw_audio`, which must
        // point at a file under the notes folder. Retain a copy in `<notes>/
        // Audio/` (mirrored dated layout, keyed to the note stem) so the link
        // survives the user moving/deleting their original import. Gated on the
        // same opt-out as live retention; best-effort, never fails the import.
        step(0.74, "Saving the audio…")
        if settings.retainMeetingAudio,
           let retained = retainImportedAudio(url, noteURL: fileURL, date: meta.date) {
            MeetingNotesWriter.setAudioPath(settings.relativePath(of: retained), to: fileURL)
        }

        // Same AI enrichment a live meeting gets (summary, action items,
        // structured extraction, unanswered questions, chapters) — gated by the
        // same settings, cloud-only. Best-effort: a failure leaves the raw
        // transcript intact.
        await enrich(fileURL: fileURL, transcript: trimmed) { fraction, label in
            step(0.78 + 0.18 * fraction, label)
        }
        step(0.98, "Filing in the Catalog…")
        registerNote(fileURL, title: title, date: meta.date)
        return fileURL
    }

    /// Add a freshly-written import to the Catalog and file it under the batch's
    /// chosen org/project. Shared by the single-file and combined paths.
    private func registerNote(_ fileURL: URL, title: String, date: Date) {
        let rel = settings.relativePath(of: fileURL)
        let note = CatalogStore.shared.note(forRelativePath: rel, title: title, date: date)
        if targetKind == "project", !targetID.isEmpty {
            CatalogStore.shared.setProject(targetID, on: note.id, true)
        } else if targetKind == "org", !targetID.isEmpty {
            CatalogStore.shared.setOrg(targetID, on: note.id, true)
        }
    }

    // MARK: Combined run

    /// Transcribe the queued files as consecutive parts of one recording and write
    /// a single note. Every part must succeed before the note is written (no
    /// half-note); a part that fails is marked failed and the others keep their
    /// transcripts, so **Retry** only re-transcribes — and re-bills — the failure.
    private func runCombined(maxBytes: Int) async {
        let group = orderedGroup()
        var failed = 0

        for idx in group where items[idx].partTranscript == nil {
            items[idx].status = .working
            items[idx].progress = 0
            let url = items[idx].url
            let ids = [items[idx].id]
            do {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if size > maxBytes {
                    throw AudioFileImporter.ImportError.tooLarge(mb: size / 1_000_000, limit: settings.audioImportMaxMB)
                }
                report(0.04, "Reading audio…", for: ids)
                let meta = await AudioFileImporter.metadata(of: url)
                report(0.08, "Transcribing…", for: ids)
                let raw = try await transcribe(url, mime: AudioFileImporter.mimeType(for: url),
                                               seconds: meta.duration ?? 0) { fraction, label in
                    self.report(0.08 + 0.62 * fraction, label, for: ids)
                }
                let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                items[idx].partTranscript = hallucinations.contains(text.lowercased())
                    ? "" : TranscriptFormatter.paragraphs(text)
                report(0.70, "Transcribed — waiting for the other parts", for: ids)
                items[idx].partDate = meta.date
                items[idx].partDuration = meta.duration
                items[idx].partBytes = size
                items[idx].error = nil
                items[idx].status = .queued          // transcribed; waiting on the other parts
            } catch {
                items[idx].error = error.localizedDescription
                items[idx].status = .failed
                failed += 1
            }
        }

        guard failed == 0 else {
            lastRun = RunSummary(done: 0, failed: failed)
            return
        }

        do {
            let note = try await writeSeriesNote(group)
            for idx in group {
                items[idx].progress = 1
                items[idx].status = .done
                items[idx].partTranscript = nil
            }
            lastRun = RunSummary(done: group.count, failed: 0)
            NotificationManager.shared.notifyAudioImported(count: group.count, fileURL: note)
        } catch {
            for idx in group {
                items[idx].error = error.localizedDescription
                items[idx].status = .failed
            }
            lastRun = RunSummary(done: 0, failed: group.count)
        }
    }

    /// Assemble the transcribed parts into one note: stitched transcript, a
    /// title from the whole, one retained recording, AI enrichment over the full
    /// text, and Catalog registration.
    private func writeSeriesNote(_ group: [Int]) async throws -> URL {
        let parts = group.map { i in
            SeriesPart(name: items[i].url.lastPathComponent, date: items[i].partDate,
                       duration: items[i].partDuration, bytes: items[i].partBytes,
                       transcript: items[i].partTranscript ?? "")
        }
        // From here every part advances together — the shared note is what's left.
        let ids = group.map { items[$0].id }
        func step(_ progress: Double, _ stage: String) { report(progress, stage, for: ids) }
        for i in group { items[i].status = .working }

        let assembled = ImportSeries.assemble(parts)
        guard assembled.hasSpeech else { throw AudioFileImporter.ImportError.emptyTranscript }
        let startedAt = assembled.startedAt ?? Date()

        // Title from the spoken content (headings would only add noise); fall back
        // to the first file's name plus the part count.
        let spoken = parts.map(\.transcript).filter { !$0.isEmpty }.joined(separator: "\n\n")
        step(0.74, "Writing a title…")
        var title = "\(items[group[0]].name) (\(parts.count) parts)"
        if !settings.localOnlyMode, KeychainService.groqAPIKey() != nil,
           let t = try? await TextPolisher().meetingTitle(transcript: spoken),
           !TranscriptFormatter.cleanTitle(t).isEmpty {
            title = TranscriptFormatter.cleanTitle(t)
        }

        step(0.80, "Saving the note…")
        guard let fileURL = MeetingNotesWriter.importAudioNote(
            transcript: assembled.transcript, recordedAt: startedAt,
            sourceFilename: parts[0].name, duration: assembled.duration,
            sourceBytes: parts[0].bytes, title: title,
            parts: parts.map { ($0.name, $0.bytes) }) else {
            throw AudioFileImporter.ImportError.decodeFailed
        }

        step(0.84, "Joining the audio…")
        if settings.retainMeetingAudio,
           let retained = await retainImportedSeries(group.map { items[$0].url }, noteURL: fileURL, date: startedAt) {
            MeetingNotesWriter.setAudioPath(settings.relativePath(of: retained), to: fileURL)
        }

        await enrich(fileURL: fileURL, transcript: assembled.transcript) { fraction, label in
            step(0.88 + 0.10 * fraction, label)
        }
        step(0.98, "Filing in the Catalog…")
        registerNote(fileURL, title: title, date: startedAt)
        return fileURL
    }

    /// Retain a series' audio as ONE playable recording: the parts joined into a
    /// single `.m4a` named for the note (so playback, Regenerate and safe-delete
    /// work as for any note). If a part can't be decoded (ogg/opus), keep each
    /// part as `<note>-partN.<ext>` and link the first. Returns the file to link,
    /// or `nil` if nothing could be retained.
    private func retainImportedSeries(_ sources: [URL], noteURL: URL, date: Date) async -> URL? {
        let dir = settings.audioDestinationFolder(for: date)
        let stem = noteURL.deletingPathExtension().lastPathComponent
        let joined = dir.appendingPathComponent("\(stem).m4a")
        // Decoding + encoding hours of audio is real work — keep it off the main
        // thread so the window stays responsive.
        let ok = await Task.detached(priority: .utility) { AudioRetainer.concatenate(sources, to: joined) }.value
        if ok { return joined }

        Log.meeting.warning("🎙️ Couldn't join the parts into one recording — keeping them separately")
        let fm = FileManager.default
        var first: URL?
        for (n, source) in sources.enumerated() {
            let ext = source.pathExtension.isEmpty ? "m4a" : source.pathExtension
            let dest = dir.appendingPathComponent("\(stem)-part\(n + 1).\(ext)")
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                try? fm.removeItem(at: dest)
                try fm.copyItem(at: source, to: dest)
                if first == nil { first = dest }
            } catch {
                Log.meeting.error("🎙️ Could not retain part \(n + 1): \(error.localizedDescription)")
            }
        }
        return first
    }

    /// Copy an imported source file into `<notes>/Audio/` (dated layout mirroring
    /// the note), named to match the note's stem so it reads like a retained
    /// recording. Returns the retained copy's URL, or `nil` on failure. Skips the
    /// copy when the source already lives under the Audio folder (e.g. the
    /// "Regenerate from audio" recovery re-importing a retained recording).
    private func retainImportedAudio(_ source: URL, noteURL: URL, date: Date) -> URL? {
        let fm = FileManager.default
        let audioRoot = settings.notesFolder.appendingPathComponent("Audio", isDirectory: true).path + "/"
        if source.path.hasPrefix(audioRoot) { return source }

        let dir = settings.audioDestinationFolder(for: date)
        let stem = noteURL.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension.isEmpty ? "m4a" : source.pathExtension
        let dest = dir.appendingPathComponent("\(stem).\(ext)")
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try? fm.removeItem(at: dest)   // overwrite any stale copy
            try fm.copyItem(at: source, to: dest)
            Log.meeting.info("🎙️ Retained imported audio → \(dest.lastPathComponent)")
            return dest
        } catch {
            Log.meeting.error("🎙️ Could not retain imported audio: \(error.localizedDescription)")
            return nil
        }
    }

    /// Append the meeting-style AI sections to a freshly-written import. Uses the
    /// General template (imports have no chosen meeting type). Cloud-only; a
    /// no-op in local-only mode or without a key.
    private func enrich(fileURL: URL, transcript: String,
                        progress: (Double, String) -> Void = { _, _ in }) async {
        guard !settings.localOnlyMode, KeychainService.groqAPIKey() != nil else { return }
        let polisher = TextPolisher()
        let writer = MeetingNotesWriter()
        let template = AppSettings.shared.template(withID: "general") ?? .builtIn(.general)

        let wantsSummary = settings.summariesEnabled
        let wantsActions = settings.actionItemsEnabled
        let wantsStructured = settings.structuredExtraction
        let wantsOpenQuestions = settings.extractUnanswered
        progress(0, "Summarizing…")
        if wantsSummary || wantsActions || wantsStructured || wantsOpenQuestions,
           let raw = try? await polisher.summarize(
               transcript: transcript, template: template,
               includeSummary: wantsSummary, includeActionItems: wantsActions,
               includeStructured: wantsStructured, includeOpenQuestions: wantsOpenQuestions),
           let clean = MeetingNotesWriter.sanitizedSummary(raw) {
            writer.appendSummary(clean, to: fileURL)
        }
        if settings.topicChapters {
            progress(0.6, "Finding chapters…")
            if let ch = try? await polisher.chapters(transcript: transcript), !ch.isEmpty {
                writer.appendChapters(ch, to: fileURL)
            }
        }
        progress(1, "")
    }

    /// `onProgress` receives (fraction 0…1 of the transcription step, a label) —
    /// it advances per chunk when a long file is split; a single-upload file jumps
    /// straight to done.
    private func transcribe(_ url: URL, mime: String, seconds: Double,
                            onProgress: @escaping (Double, String) -> Void = { _, _ in }) async throws -> String {
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
                return Redactor.redact(try await cloudTranscribe(pcm16k: pcm, onProgress: onProgress))
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
    private func cloudTranscribe(pcm16k: Data,
                                 onProgress: (Double, String) -> Void) async throws -> String {
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
            onProgress(Double(i) / Double(chunks.count), "Transcribing part \(i + 1) of \(chunks.count)…")
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
