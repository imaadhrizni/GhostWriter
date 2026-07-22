import Foundation

// MARK: - Meeting Refinery
//
// The end-of-meeting AI "refinement" pass, factored out of the live finalizer
// so it can be re-run on demand. Given a saved note file and its transcript it
// (re)generates the Summary, Key Details, Agenda, Chapters, and Mentions
// sections — via the cloud in the normal path, or on-device in Local-only mode.
//
// One source of truth for two callers:
//   • `GhostWriterApp.finalizeMeetingNotes` runs it once when a meeting ends.
//   • The notes viewer runs it manually (`stripExisting: true`) to retry after
//     a failure (e.g. a decommissioned model) or to refresh a note.
//
// It is deliberately self-contained: TextPolisher + MeetingNotesWriter +
// AppSettings + on-device NLP, no live-meeting state. Voice-identity naming,
// bookmarks, Catalog linking, and event dispatch stay in the live finalizer.

@MainActor
enum MeetingRefinery {

    /// Top-level Markdown headings this pass produces. Removed before a manual
    /// re-run so re-running never duplicates a section. `Bookmarks` and the
    /// transcript are intentionally excluded — they're not regenerated.
    static let generatedHeadings = ["Summary", "Key Details", "Agenda", "Chapters", "Mentions"]

    struct Options {
        /// The user's planned agenda (live meeting only).
        var userAgenda: [String] = []
        /// The live panel's accumulated coverage (preferred over a fresh scan).
        var liveAgenda: [(text: String, covered: Bool, dynamic: Bool)] = []
        /// Strip previously generated sections first (manual re-run).
        var stripExisting = false
    }

    /// Run the refinement over `fileURL`. `transcript` is the note's dialogue
    /// (read by the caller). `onError` is invoked per failed step so the caller
    /// can surface it (a toast for the live path, inline status for the viewer).
    /// Returns whether any section was (re)generated.
    @discardableResult
    static func refine(fileURL: URL,
                       transcript: String,
                       options: Options = Options(),
                       onError: @escaping (String) -> Void = { _ in }) async -> Bool {
        // Enough real speech to work with? Measure dialogue, not header/markers.
        guard dialogueLength(of: transcript) > 200 else {
            onError("Not enough conversation in this note to refine.")
            return false
        }

        let settings = AppSettings.shared
        let writer = MeetingNotesWriter()

        if options.stripExisting { stripGeneratedSections(from: fileURL) }

        // Keyword/competitor radar — a purely local scan (works offline).
        let watchTerms = settings.watchlist()
        if !watchTerms.isEmpty {
            let matches = MeetingNotesWriter.mentionCounts(in: transcript, terms: watchTerms)
            if !matches.isEmpty {
                writer.appendMentions(matches, to: fileURL)
                if settings.frontMatterEnabled {
                    MeetingNotesWriter.addFrontMatterTags(matches.map { $0.term }, to: fileURL)
                }
            }
        }

        if settings.localOnlyMode {
            return await refineOnDevice(fileURL: fileURL, transcript: transcript, writer: writer)
        }
        return await refineCloud(fileURL: fileURL, transcript: transcript,
                                 options: options, writer: writer, onError: onError)
    }

    // MARK: Cloud

    private static func refineCloud(fileURL: URL, transcript: String, options: Options,
                                    writer: MeetingNotesWriter,
                                    onError: @escaping (String) -> Void) async -> Bool {
        let settings = AppSettings.shared
        let tp = TextPolisher()
        var produced = false

        let wantsSummary = settings.summariesEnabled
        let wantsActions = settings.actionItemsEnabled
        let wantsStructured = settings.structuredExtraction
        let wantsOpenQuestions = settings.extractUnanswered
        let wantsSummarySection = wantsSummary || wantsActions || wantsStructured || wantsOpenQuestions

        let wantsTitle = settings.frontMatterEnabled
        let wantsMeta  = settings.autoTagging && settings.frontMatterEnabled
        let wantsFields = settings.extractKeyFields
        let wantsFacts = wantsTitle || wantsMeta || wantsFields
        let includePeople = !settings.redactionEnabled
        let schema = wantsFields ? settings.selectedTemplate.keyFields : []

        // Fan out the independent model calls concurrently — the AIGate bounds
        // how many actually run at once. Each is independently optional so one
        // failure never cancels the others (same graceful degradation as the
        // old sequential path), and the FILE WRITES are done afterwards, in the
        // canonical section order, so concurrent calls never race on the note.
        async let summaryRawTask: String? = wantsSummarySection
            ? (try? await tp.summarize(
                transcript: transcript, template: settings.selectedTemplate,
                includeSummary: wantsSummary, includeActionItems: wantsActions,
                includeStructured: wantsStructured, includeOpenQuestions: wantsOpenQuestions))
            : nil
        async let factsTask: TextPolisher.MeetingFacts? = wantsFacts
            ? await tp.extractMeetingFacts(
                transcript: transcript, includeTitle: wantsTitle,
                includePeople: includePeople, fields: schema)
            : nil
        async let chaptersTask: String? = settings.topicChapters
            ? (try? await tp.chapters(transcript: transcript))
            : nil
        async let agendaStatusTask: TextPolisher.AgendaStatus? = options.liveAgenda.isEmpty
            ? await tp.agendaStatus(userAgenda: options.userAgenda, transcript: transcript, preferFast: true)
            : nil

        let summaryRaw = await summaryRawTask
        let facts = await factsTask
        let chaptersText = await chaptersTask
        let agendaStatus = await agendaStatusTask

        // --- Writes, serialized in canonical order ---

        // Summary.
        if wantsSummarySection {
            if let raw = summaryRaw, let summary = MeetingNotesWriter.sanitizedSummary(raw) {
                writer.appendSummary(summary, to: fileURL)
                produced = true
            } else if summaryRaw == nil {
                Log.meeting.error("❌ Summary failed or returned nothing")
                onError("Meeting summary failed.")
            } else {
                Log.meeting.info("⏭ Summary skipped — not enough content")
            }
        }

        // Meeting facts — title (front-matter), topic/entity metadata, per-type
        // key fields (one fast structured call above).
        if let facts {
            if wantsTitle, !facts.title.isEmpty {
                MeetingNotesWriter.setFrontMatterTitle(facts.title, to: fileURL)
                CatalogStore.shared.renameNote(
                    relativePath: AppSettings.shared.relativePath(of: fileURL), to: facts.title)
            }
            if wantsMeta {
                var meta = facts.metadata
                if meta.isEmpty {
                    meta = OnDeviceNLP.extractMetadata(transcript: transcript, includePeople: includePeople)
                }
                if !meta.isEmpty {
                    let customer = validatedCustomer(meta.customer)
                    MeetingNotesWriter.addMeetingMetadata(
                        topics: meta.topics, people: meta.people,
                        customer: customer, project: meta.project, to: fileURL)
                }
            }
            if wantsFields, !facts.keyFields.isEmpty {
                writer.appendKeyDetails(facts.keyFields.map { ($0.field.label, $0.value) }, to: fileURL)
                produced = true
                if settings.frontMatterEnabled {
                    MeetingNotesWriter.addFrontMatterFields(
                        facts.keyFields.map { ($0.field.key, $0.value) }, to: fileURL)
                    let categories = facts.keyFields
                        .filter { $0.field.kind == .category }
                        .map { ($0.field.key, $0.value) }
                    MeetingNotesWriter.mirrorFieldsToTags(categories, to: fileURL)
                }
            }
        }

        // Chapters.
        if let chaptersText, !chaptersText.isEmpty {
            writer.appendChapters(chaptersText, to: fileURL); produced = true
        }

        // Agenda: the live panel's accumulated coverage, else the one-shot scan.
        if !options.liveAgenda.isEmpty {
            writer.appendAgenda(options.liveAgenda, to: fileURL); produced = true
        } else if let status = agendaStatus {
            let userEntries = zip(options.userAgenda, status.userCovered)
                .map { (text: $0.0, covered: $0.1, dynamic: false) }
            let dynEntries = status.newTopics.map { (text: $0, covered: false, dynamic: true) }
            let entries = userEntries + dynEntries
            if !entries.isEmpty { writer.appendAgenda(entries, to: fileURL); produced = true }
        }

        return produced
    }

    // MARK: On-device (Local-only mode)

    private static func refineOnDevice(fileURL: URL, transcript: String,
                                       writer: MeetingNotesWriter) async -> Bool {
        let settings = AppSettings.shared
        var produced = false

        if (settings.summariesEnabled || settings.actionItemsEnabled), AppleIntelligence.isAvailable {
            let sections = settings.summariesEnabled ? settings.selectedTemplate.summarySections : []
            if let raw = await AppleIntelligence.summarizeMeeting(
                transcript: transcript, sections: sections, includeActionItems: settings.actionItemsEnabled),
               let summary = MeetingNotesWriter.sanitizedSummary(raw) {
                writer.appendSummary(summary + "\n\n_— generated on-device with Apple Intelligence_", to: fileURL)
                produced = true
            } else {
                Log.meeting.info("⏭ On-device summary unavailable or empty")
            }
        }

        if settings.autoTagging, settings.frontMatterEnabled {
            let meta = OnDeviceNLP.extractMetadata(
                transcript: transcript, includePeople: !settings.redactionEnabled)
            if !meta.isEmpty {
                let customer = validatedCustomer(meta.customer)
                MeetingNotesWriter.addMeetingMetadata(
                    topics: meta.topics, people: meta.people,
                    customer: customer, project: meta.project, to: fileURL)
            }
        }
        return produced
    }

    // MARK: Helpers

    /// How much real content there is to summarize. Live meetings write
    /// timestamped dialogue (`**[timestamp]** …`), so those lines are the
    /// truest measure. Imported or re-transcribed notes have no timestamp
    /// markers — for those we fall back to counting substantive body text
    /// (anything that isn't a heading, a divider, or an event marker) so they
    /// can still be refined rather than being wrongly rejected as "not enough
    /// content". Callers should strip previously-generated sections first so a
    /// prior summary isn't counted as content.
    static func dialogueLength(of transcript: String) -> Int {
        let lines = transcript.split(whereSeparator: \.isNewline)
        let spoken = lines.filter { $0.hasPrefix("**[") }.reduce(0) { $0 + $1.count }
        if spoken > 0 { return spoken }
        return lines.reduce(0) { total, line in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, !t.hasPrefix("#"), t != "---", !t.hasPrefix("*[") else { return total }
            return total + t.count
        }
    }

    /// Guard against low-confidence `customer` guesses from entity extraction:
    /// accept a name matching a known Catalog org/project (or alias), otherwise
    /// drop a lone short token or all-caps acronym (usually transcript noise).
    static func validatedCustomer(_ raw: String?) -> String? {
        guard let name = raw?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
        let store = CatalogStore.shared
        let known = store.doc.orgs.flatMap { [$0.name] + $0.aliases } + store.doc.projects.map(\.name)
        if known.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { return name }
        let tokens = name.split(whereSeparator: { $0 == " " })
        if tokens.count == 1 {
            let t = String(tokens[0])
            if t.count <= 3 || t == t.uppercased() { return nil }
        }
        return name
    }

    /// Remove the generated sections (`# Summary`, `## Key Details`, `# Agenda`,
    /// `# Chapters`, `# Mentions`) from a note file, leaving front-matter, the
    /// header, transcript, and any Bookmarks intact — so a re-run replaces
    /// rather than duplicates. Matching is on the heading text, at any `#` depth.
    ///
    /// A generated section's body may itself contain sub-headings — the Summary
    /// carries `## Decisions`, `## Action Items`, etc. — so we keep dropping a
    /// section's body until we reach either another generated heading or a
    /// **top-level** (`# `) heading (a real new section such as the note header,
    /// Bookmarks, or the transcript). Stopping at any heading would leave those
    /// summary sub-sections behind, which is exactly what produced duplicated
    /// content on re-run / template change.
    static func stripGeneratedSections(from fileURL: URL) {
        guard let text = fileURL.readText() else { return }
        let headings = Set(generatedHeadings.map { $0.lowercased() })
        let lines = text.components(separatedBy: "\n")
        var out: [String] = []
        var skipping = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                let hashes = trimmed.prefix { $0 == "#" }.count
                let title = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).lowercased()
                if headings.contains(title) {
                    skipping = true          // drop this heading and its body …
                    continue
                }
                // … until the next generated heading (handled above) or a
                // top-level heading. A deeper (`## `+) non-generated heading is
                // part of the generated section's body, so keep dropping it.
                if skipping, hashes == 1 { skipping = false }
            }
            if !skipping { out.append(line) }
        }
        // Collapse the runs of blank lines a removal can leave behind.
        var collapsed: [String] = []
        for line in out {
            if line.trimmingCharacters(in: .whitespaces).isEmpty,
               collapsed.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { continue }
            collapsed.append(line)
        }
        let result = collapsed.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        try? result.write(to: fileURL, atomically: true, encoding: .utf8)
    }
}
