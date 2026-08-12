import Foundation

// Supporting value types for AppSettings: meeting templates, dictation styles,
// summary/extraction shapes, and enum-backed option types. Split out of
// AppSettings.swift to keep the settings store focused on the keyed values.

// MARK: - Meeting Template

/// Shapes what the end-of-meeting summary extracts. Each template defines its
/// own Markdown sections; Action Items is appended separately when enabled.
/// One machine-readable field a meeting type is worth extracting — captured
/// into the note's YAML front-matter (queryable by Obsidian/Dataview) and, for
/// `.category` fields, mirrored into `tags:` so they're filterable in the
/// Catalog with the existing tag filter.
struct ExtractionField: Hashable {
    enum Kind { case text, category }
    let key: String       // front-matter key suffix, e.g. "deal_stage" → gw_deal_stage
    let label: String     // human label for the Key Details section, e.g. "Deal stage"
    let hint: String      // guidance to the model (allowed values for categories)
    let kind: Kind
}

enum MeetingTemplate: String, CaseIterable, Identifiable {
    // Sales-engineering-focused defaults, plus common team meeting types.
    // (Interview and Retrospective are intentionally not built in — add them
    // as a custom template if needed.)
    case general, customerCall, discovery, solutionDemo, solutionScoping,
         kickoff, planning, standup, oneOnOne, allHands, brainstorm, lecture

    var id: String { rawValue }

    /// Broad category used to group the meeting-type pickers so the list reads
    /// as a few short labeled sections rather than one long wall.
    enum Category: String, CaseIterable {
        case sales, delivery, team, other
        var title: String {
            switch self {
            case .sales:    return "Sales & Customer"
            case .delivery: return "Delivery & Project"
            case .team:     return "Team & Internal"
            case .other:    return "Other"
            }
        }
    }

    var category: Category {
        switch self {
        case .customerCall, .discovery, .solutionDemo, .solutionScoping: return .sales
        case .kickoff, .planning:                                        return .delivery
        case .standup, .oneOnOne, .allHands, .brainstorm:                return .team
        case .lecture, .general:                                         return .other
        }
    }

    /// One-line description shown under the picker to explain what this type
    /// captures and when to reach for it.
    var blurb: String {
        switch self {
        case .general:       return "A neutral catch-all: a short TL;DR plus any decisions."
        case .customerCall:  return "An account call — needs, objections, and commitments, with deal fields."
        case .planning:      return "Scoping/planning — scope, estimates, and risks."
        case .kickoff:       return "A project kickoff — goals, scope, roles, milestones, and risks."
        case .discovery:     return "A discovery call — current state, desired outcomes, and requirements."
        case .solutionDemo:  return "A technical demo — use cases shown, technical fit, and objections."
        case .solutionScoping: return "A solutioning session — requirements, approach, scope, and dependencies."
        case .standup:       return "Daily team sync — per-person updates and blockers."
        case .oneOnOne:      return "A private 1:1 — topics, feedback, and growth notes."
        case .allHands:      return "A team- or company-wide update — announcements, highlights, and Q&A."
        case .brainstorm:    return "An ideation session — every idea plus the promising directions."
        case .lecture:       return "A talk or webinar — key concepts, takeaways, and follow-ups."
        }
    }

    /// The draft documents most useful to produce from this meeting type —
    /// surfaced first in the note viewer's Draft… menu.
    var suggestedDrafts: [FollowUpKind] {
        switch self {
        case .customerCall:    return [.followUpEmail, .proposal, .actionItemList]
        case .discovery:       return [.followUpEmail, .proposal, .pocPlan]
        case .solutionDemo:    return [.followUpEmail, .pocPlan, .proposal]
        case .solutionScoping: return [.pocPlan, .proposal, .actionItemList]
        case .kickoff:         return [.minutes, .actionItemList, .statusUpdate]
        case .planning:        return [.actionItemList, .statusUpdate, .minutes]
        case .standup:         return [.statusUpdate, .actionItemList, .recap]
        case .oneOnOne:        return [.recap, .actionItemList, .thankYou]
        case .allHands:        return [.recap, .faq, .minutes]
        case .brainstorm:      return [.recap, .talkingPoints, .actionItemList]
        case .lecture:         return [.recap, .faq, .actionItemList]
        case .general:         return [.recap, .followUpEmail, .actionItemList]
        }
    }

    /// The high-signal fields this meeting type is worth extracting into the
    /// front-matter. Empty for types where the prose summary already says it
    /// all. `.category` fields are also mirrored into tags for Catalog filtering.
    var keyFields: [ExtractionField] {
        switch self {
        case .customerCall: return [
            .init(key: "deal_stage", label: "Deal stage",
                  hint: "one of: prospecting, discovery, proposal, negotiation, closed-won, closed-lost",
                  kind: .category),
            .init(key: "budget", label: "Budget", hint: "budget or deal size if stated (e.g. $50k)", kind: .text),
            .init(key: "timeline", label: "Timeline", hint: "target date or timeframe if stated (e.g. Q3, by March)", kind: .text),
            .init(key: "decision_maker", label: "Decision maker", hint: "the person who decides, if named", kind: .text),
            .init(key: "next_step", label: "Next step", hint: "the single most important next action", kind: .text),
        ]
        case .planning: return [
            .init(key: "target_date", label: "Target date", hint: "the agreed delivery date or milestone, if stated", kind: .text),
            .init(key: "top_risk", label: "Top risk", hint: "the single biggest risk or dependency", kind: .text),
        ]
        case .oneOnOne: return [
            .init(key: "sentiment", label: "Sentiment",
                  hint: "the report's overall mood: positive, neutral, or concerned", kind: .category),
            .init(key: "focus", label: "Focus next time", hint: "the main topic to revisit next 1:1", kind: .text),
        ]
        case .brainstorm: return [
            .init(key: "top_idea", label: "Most promising idea", hint: "the idea that got the most traction", kind: .text),
        ]
        case .kickoff: return [
            .init(key: "target_date", label: "Target date", hint: "the agreed launch/delivery date or first milestone, if stated", kind: .text),
            .init(key: "top_risk", label: "Top risk", hint: "the single biggest risk or dependency raised", kind: .text),
        ]
        case .discovery: return [
            .init(key: "primary_need", label: "Primary need", hint: "the most important problem the prospect wants solved", kind: .text),
            .init(key: "timeline", label: "Timeline", hint: "target date or timeframe if stated (e.g. Q3, by March)", kind: .text),
            .init(key: "next_step", label: "Next step", hint: "the single most important next action", kind: .text),
        ]
        case .solutionDemo: return [
            .init(key: "technical_fit", label: "Technical fit",
                  hint: "how well the solution matched the requirements: strong, partial, or gaps", kind: .category),
            .init(key: "top_blocker", label: "Top blocker", hint: "the biggest technical objection, gap, or missing capability", kind: .text),
            .init(key: "next_step", label: "Next step", hint: "the single most important next action (e.g. POC, security review)", kind: .text),
        ]
        case .solutionScoping: return [
            .init(key: "scope_clarity", label: "Scope clarity",
                  hint: "how well-defined the scope is: clear, partial, or unclear", kind: .category),
            .init(key: "top_dependency", label: "Top dependency", hint: "the biggest dependency or prerequisite that could block progress", kind: .text),
            .init(key: "next_step", label: "Next step", hint: "the single most important next action", kind: .text),
        ]
        case .general, .standup, .lecture, .allHands:
            return []
        }
    }

    var displayName: String {
        switch self {
        case .general:       return "General"
        case .customerCall:  return "Customer Call"
        case .planning:      return "Planning"
        case .kickoff:       return "Project Kickoff"
        case .discovery:     return "Discovery Call"
        case .solutionDemo:  return "Solution Demo"
        case .solutionScoping: return "Solution Scoping"
        case .standup:       return "Standup"
        case .oneOnOne:      return "1:1"
        case .allHands:      return "All-Hands"
        case .brainstorm:    return "Brainstorm"
        case .lecture:       return "Lecture / Webinar"
        }
    }

    /// The built-in sections for this template, as (heading, instruction)
    /// pairs. Action Items is excluded — it has its own toggle.
    var defaultSections: [(heading: String, instruction: String)] {
        switch self {
        case .general: return [
            ("TL;DR", "2-3 sentences."),
            ("Decisions", "bullet list of decisions made (omit the section if none)."),
        ]
        case .standup: return [
            ("Updates", "one bullet per person: what they did / are doing (use speaker labels when names are unknown)."),
            ("Blockers", "bullet list of blockers raised and who owns unblocking (omit if none)."),
        ]
        case .oneOnOne: return [
            ("Topics", "bullet list of topics discussed."),
            ("Feedback", "feedback exchanged, in either direction (omit if none)."),
            ("Growth & Career", "career/growth notes (omit if none)."),
        ]
        case .customerCall: return [
            ("Customer Needs", "pain points and needs the customer expressed."),
            ("Objections & Concerns", "hesitations or objections raised (omit if none)."),
            ("Commitments", "what was promised to the customer, by whom (omit if none)."),
        ]
        case .planning: return [
            ("Scope", "what was agreed to be in and out of scope."),
            ("Estimates & Commitments", "sizes, dates, owners agreed (omit if none)."),
            ("Risks", "risks and dependencies raised (omit if none)."),
        ]
        case .kickoff: return [
            ("Goals & Success Criteria", "what this project/effort is trying to achieve and how success is measured."),
            ("Scope", "what was agreed to be in and out of scope (omit if not discussed)."),
            ("Roles & Responsibilities", "who owns what — people or teams and their remit."),
            ("Milestones & Timeline", "key dates and milestones agreed (omit if none)."),
            ("Risks & Dependencies", "risks, unknowns, and dependencies raised (omit if none)."),
        ]
        case .discovery: return [
            ("Current State", "the prospect's situation today — how they handle this now, and the pain points."),
            ("Desired Outcomes", "what they want to achieve or change."),
            ("Requirements", "explicit needs, must-haves, and evaluation criteria (omit if none)."),
            ("Constraints", "budget, timeline, or other constraints mentioned (omit if none)."),
        ]
        case .solutionDemo: return [
            ("Use Cases Shown", "the capabilities or workflows demonstrated, and the prospect's reaction to each."),
            ("Technical Fit", "how well the solution matched the stated requirements — what landed well."),
            ("Objections & Gaps", "technical objections, missing capabilities, or concerns raised (omit if none)."),
            ("Next Steps", "agreed follow-ups — POC, security/technical review, further demos — with owners (omit if none)."),
        ]
        case .solutionScoping: return [
            ("Requirements", "the functional and technical requirements the solution must meet."),
            ("Proposed Approach", "the solution or architecture proposed, and how it addresses the requirements."),
            ("In / Out of Scope", "what was agreed to be in scope and explicitly out of scope."),
            ("Dependencies & Prerequisites", "integrations, access, data, or environment needed from either side (omit if none)."),
            // Open Questions is a first-class, toggle-driven section (the same
            // `## Open Questions` checkbox list every meeting type gets) — kept
            // out of the template so it isn't emitted twice and downgraded to
            // plain bullets by the heading-dedup.
        ]
        case .allHands: return [
            ("Announcements", "the key announcements or news shared."),
            ("Highlights", "notable updates, wins, or metrics presented."),
            ("Q&A", "questions raised and the answers given (omit if none)."),
        ]
        case .brainstorm: return [
            ("Ideas", "every distinct idea raised, one bullet each."),
            ("Promising Directions", "the ideas that got traction and why."),
        ]
        case .lecture: return [
            ("Key Concepts", "the main ideas presented, briefly explained."),
            ("Takeaways", "practical takeaways."),
            ("Follow-ups", "questions or topics to research afterward (omit if none)."),
        ]
        }
    }

    /// The default sections as editable text — one `Heading: instruction`
    /// line per section. This is what the Settings editor pre-fills and
    /// resets to.
    var defaultSectionsText: String {
        defaultSections.map { "\($0.heading): \($0.instruction)" }.joined(separator: "\n")
    }

    /// Summary section specs (exact heading + what goes in it) fed to the
    /// model, excluding Action Items. Honors a user override from Settings
    /// when one exists; otherwise uses the built-in defaults.
    var summarySections: [String] {
        if let custom = AppSettings.shared.customTemplateSections(for: self) {
            return Self.parseSections(custom)
        }
        return defaultSections.map { sect($0.heading, $0.instruction) }
    }

    /// Parse `Heading: instruction` lines (the Settings editor format) into
    /// model-facing section specs. Blank lines and lines without a heading
    /// are skipped; a line with no colon is treated as a heading with a
    /// generic instruction.
    static func parseSections(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return nil }
            if let colon = line.firstIndex(of: ":") {
                let heading = line[..<colon].trimmingCharacters(in: .whitespaces)
                let instruction = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                guard !heading.isEmpty else { return nil }
                return sect(heading, instruction.isEmpty ? "the relevant content (omit if none)." : instruction)
            }
            return sect(line, "the relevant content (omit if none).")
        }
    }

    private static func sect(_ heading: String, _ instruction: String) -> String {
        "A section with the exact heading \"## \(heading)\" containing \(instruction)"
    }

    private func sect(_ heading: String, _ instruction: String) -> String {
        Self.sect(heading, instruction)
    }

    /// How a follow-up message for this meeting type should be shaped —
    /// recipient, tone, and what to include. Fed to the follow-up drafter.
    var followUpGuidance: String {
        switch self {
        case .general:
            return "Write a concise recap email to the participants: key outcomes and clear next steps with owners."
        case .standup:
            return "Write a short INTERNAL status update (not a formal email): what's done, what's next, and blockers with owners. Terse and skimmable."
        case .oneOnOne:
            return "Write a brief, warm private recap for the two participants: topics discussed, agreements reached, and any growth/career follow-ups."
        case .allHands:
            return "Write a team-wide recap: the key announcements, highlights, and concise answers to the main questions raised, plus any action items with owners."
        case .brainstorm:
            return "Write a recap: the ideas raised, the most promising directions, and agreed next steps to explore them."
        case .lecture:
            return "Write a learner-oriented recap: key concepts, practical takeaways, and follow-up resources or questions to explore."
        case .customerCall:
            return "Write a polished, client-facing follow-up EMAIL to the customer. Thank them, restate the needs they raised, confirm the commitments made, and lay out next steps with owners and timing. Professional and warm."
        case .planning:
            return "Write an internal follow-up: agreed scope (in/out), estimates and dates, owners, and open risks or dependencies."
        case .kickoff:
            return "Write an internal kickoff recap for the team: the goals and success criteria, agreed scope, who owns what, key milestones and timeline, and open risks or dependencies."
        case .discovery:
            return "Write a follow-up summarizing what you learned: the prospect's current situation and pain points, their desired outcomes, key requirements and constraints, and the proposed next steps. Client-appropriate but grounded strictly in what was said."
        case .solutionDemo:
            return "Write a client-facing follow-up EMAIL after a solution demo: thank them, recap the use cases shown and how they map to the requirements, address any open objections or gaps with clear next steps (POC, technical/security review, further demos) and owners. Professional and confident, grounded strictly in what was demonstrated and discussed."
        case .solutionScoping:
            return "Write a follow-up summarizing the scoping outcome: the agreed requirements, the proposed approach, what's in and out of scope, key dependencies/prerequisites, and open questions with owners. Precise and grounded strictly in what was discussed."
        }
    }

    /// Best-guess template from a finished note's section headings — used when
    /// drafting a follow-up for a past meeting whose template isn't recorded.
    /// Returns nil when nothing distinctive matches (caller falls back).
    static func inferred(fromNotes content: String) -> MeetingTemplate? {
        let lc = content.lowercased()
        func has(_ heading: String) -> Bool { lc.contains("## \(heading.lowercased())") }

        if has("Customer Needs") || has("Objections & Concerns") { return .customerCall }
        if has("Use Cases Shown") || has("Technical Fit") { return .solutionDemo }
        if has("Proposed Approach") || has("In / Out of Scope") { return .solutionScoping }
        if has("Desired Outcomes") || has("Current State") { return .discovery }
        if has("Roles & Responsibilities") || (has("Goals & Success Criteria")) { return .kickoff }
        if has("Announcements") { return .allHands }
        if has("Updates") && has("Blockers") { return .standup }
        if has("Scope") && has("Risks") { return .planning }
        if has("Key Concepts") || has("Takeaways") { return .lecture }
        if has("Promising Directions") { return .brainstorm }
        if has("Growth & Career") { return .oneOnOne }
        return nil
    }
}

// MARK: - User Templates

/// A user-created template: a name plus its editable section text
/// (`Heading: instruction` lines). Persisted as JSON in AppSettings.
struct UserTemplate: Codable, Identifiable, Hashable {
    var id: String        // "user:UUID"
    var name: String
    var sections: String
    /// Optional custom follow-up guidance; empty → a generic default is used.
    /// Defaulted so JSON saved before this field existed still decodes.
    var followUp: String = ""
}

/// A portable bundle of user-customized template data, for Export / Import in
/// the Settings template panes. Every field is defaulted and decoded
/// tolerantly (see `init(from:)`) so a bundle written by any version — or one
/// missing a section — still imports cleanly.
struct TemplateBundle: Codable {
    var version: Int = 1
    var userTemplates: [UserTemplate] = []
    var userDraftTemplates: [UserDraftTemplate] = []
    var meetingSectionOverrides: [String: String] = [:]
    var meetingFollowUpOverrides: [String: String] = [:]
    var draftGuidanceOverrides: [String: String] = [:]

    init(version: Int = 1,
         userTemplates: [UserTemplate] = [],
         userDraftTemplates: [UserDraftTemplate] = [],
         meetingSectionOverrides: [String: String] = [:],
         meetingFollowUpOverrides: [String: String] = [:],
         draftGuidanceOverrides: [String: String] = [:]) {
        self.version = version
        self.userTemplates = userTemplates
        self.userDraftTemplates = userDraftTemplates
        self.meetingSectionOverrides = meetingSectionOverrides
        self.meetingFollowUpOverrides = meetingFollowUpOverrides
        self.draftGuidanceOverrides = draftGuidanceOverrides
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        userTemplates = try c.decodeIfPresent([UserTemplate].self, forKey: .userTemplates) ?? []
        userDraftTemplates = try c.decodeIfPresent([UserDraftTemplate].self, forKey: .userDraftTemplates) ?? []
        meetingSectionOverrides = try c.decodeIfPresent([String: String].self, forKey: .meetingSectionOverrides) ?? [:]
        meetingFollowUpOverrides = try c.decodeIfPresent([String: String].self, forKey: .meetingFollowUpOverrides) ?? [:]
        draftGuidanceOverrides = try c.decodeIfPresent([String: String].self, forKey: .draftGuidanceOverrides) ?? [:]
    }
}

/// A resolved template — built-in or user-defined — that the pickers, the
/// summary prompt, and the section editor all consume uniformly.
enum SummaryTemplate: Identifiable, Hashable {
    case builtIn(MeetingTemplate)
    case user(UserTemplate)

    var id: String {
        switch self {
        case .builtIn(let t): return t.rawValue
        case .user(let t):    return t.id
        }
    }

    var displayName: String {
        switch self {
        case .builtIn(let t): return t.displayName
        case .user(let t):    return t.name
        }
    }

    var isBuiltIn: Bool {
        if case .builtIn = self { return true }
        return false
    }

    /// The editable `Heading: instruction` text — a built-in's override or
    /// defaults, or the user template's own sections.
    var sectionsText: String {
        switch self {
        case .builtIn(let t): return AppSettings.shared.customTemplateSections(for: t) ?? t.defaultSectionsText
        case .user(let t):    return t.sections
        }
    }

    /// The model-facing section specs fed to the summarizer.
    var summarySections: [String] {
        switch self {
        case .builtIn(let t): return t.summarySections
        case .user(let t):    return MeetingTemplate.parseSections(t.sections)
        }
    }

    /// The machine-readable fields to extract for this meeting type. User
    /// templates have no schema yet, so they extract nothing.
    var keyFields: [ExtractionField] {
        switch self {
        case .builtIn(let t): return t.keyFields
        case .user:           return []
        }
    }

    /// Generic follow-up guidance for a user template with no custom text.
    static func genericFollowUp(name: String) -> String {
        "Write a concise follow-up appropriate to a \(name) meeting, building on the notes: key outcomes and clear next steps with owners."
    }

    /// How a follow-up for this meeting type should be shaped — the resolved
    /// guidance fed to the drafter (custom override, then built-in/generic default).
    var followUpGuidance: String {
        switch self {
        case .builtIn(let t): return AppSettings.shared.customTemplateFollowUp(for: t) ?? t.followUpGuidance
        case .user(let t):
            return t.followUp.isEmpty ? Self.genericFollowUp(name: t.name) : t.followUp
        }
    }

    /// The editable follow-up text shown in the editor — a built-in's override
    /// or default, or the user template's own (possibly the generic default).
    var followUpText: String {
        switch self {
        case .builtIn(let t): return AppSettings.shared.customTemplateFollowUp(for: t) ?? t.followUpGuidance
        case .user(let t):    return t.followUp.isEmpty ? Self.genericFollowUp(name: t.name) : t.followUp
        }
    }
}

// MARK: - Dictation Styles

/// A user-created dictation writing style: a name plus its free-text
/// instruction. Persisted as JSON in AppSettings.
struct UserStyle: Codable, Identifiable, Hashable {
    var id: String        // "user:UUID"
    var name: String
    var instruction: String
}

/// A resolved dictation style — a built-in app category or a user style —
/// consumed uniformly by the polisher and the style editor.
enum DictationStyle: Identifiable, Hashable {
    case builtIn(AppCategory)
    case user(UserStyle)

    var id: String {
        switch self {
        case .builtIn(let c): return c.rawValue
        case .user(let s):    return s.id
        }
    }

    var displayName: String {
        switch self {
        case .builtIn(let c): return c.displayName
        case .user(let s):    return s.name
        }
    }

    var isBuiltIn: Bool {
        if case .builtIn = self { return true }
        return false
    }

    /// The writing-style instruction appended to the base polishing prompt —
    /// a built-in's override or default, or the user style's own text.
    var instruction: String {
        switch self {
        case .builtIn(let c): return AppSettings.shared.dictationStyleOverride(for: c) ?? c.defaultInstruction
        case .user(let s):    return s.instruction
        }
    }
}

// MARK: - Notes Organization

/// Folder layout for meeting notes. Applies to new meetings only —
/// existing files stay where they are (all lookups search recursively).
enum NotesOrganization: String, CaseIterable, Identifiable {
    case flat       // everything directly in the notes folder
    case byDay      // Notes/2026/2026-07/03/
    case byMonth    // Notes/2026/2026-07/
    case byYear     // Notes/2026/

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .flat:    return "Single folder"
        case .byDay:   return "Year / month / day (2026/2026-07/03/)"
        case .byMonth: return "Year / month (2026/2026-07/)"
        case .byYear:  return "Year (2026/)"
        }
    }
}

// MARK: - Meeting Overlay Mode

/// Display behavior of the floating overlay during Meeting Mode.
enum MeetingOverlayMode: String, CaseIterable, Identifiable {
    case captions   // pill + live transcript captions
    case minimal    // small recording-indicator pill, no transcript text
    case hidden     // no overlay at all (menu-bar icon is the only indicator)

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .captions: return "Pill with live captions"
        case .minimal:  return "Minimal pill (no captions)"
        case .hidden:   return "Hidden"
        }
    }

    var help: String {
        switch self {
        case .captions: return "Shows the latest transcribed line as it arrives."
        case .minimal:  return "A small recording indicator — nothing readable. Good for screen sharing."
        case .hidden:   return "Nothing on screen. The menu-bar headphones icon is the only sign a meeting is being recorded."
        }
    }
}

// MARK: - Push-to-Talk Key Options

/// Modifier keys usable as the push-to-talk hotkey (flagsChanged-based).
/// How the push-to-talk key drives dictation recording.
enum PTTActivation: String, CaseIterable, Identifiable {
    /// Record only while the key is physically held; stop on release. (Classic push-to-talk.)
    case hold
    /// Hold-to-talk still works, but a quick tap latches recording hands-free
    /// until the next tap. Best of both for short phrases and long dictations.
    case tapLock
    /// Press once to start, press again to stop — the key never needs holding.
    case toggle

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .hold:    return "Hold to talk"
        case .tapLock: return "Tap to lock (hybrid)"
        case .toggle:  return "Press to toggle"
        }
    }

    var detail: String {
        switch self {
        case .hold:    return "Record while the key is held; transcribe and type on release."
        case .tapLock: return "Hold for a quick phrase, or tap once to latch hands-free — tap again (or Esc) to stop."
        case .toggle:  return "Press once to start recording, press again to stop. The key is never held."
        }
    }
}

enum PTTKey: Int, CaseIterable, Identifiable {
    case rightOption  = 61
    case leftOption   = 58
    case rightCommand = 54
    case rightControl = 62
    case fn           = 63

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .rightOption:  return "Right Option (⌥)"
        case .leftOption:   return "Left Option (⌥)"
        case .rightCommand: return "Right Command (⌘)"
        case .rightControl: return "Right Control (⌃)"
        case .fn:           return "Fn (Globe)"
        }
    }

    /// The CGEventFlags mask that indicates this modifier is held down.
    var flagMask: UInt64 {
        switch self {
        case .rightOption, .leftOption: return 0x00080000  // maskAlternate
        case .rightCommand:             return 0x00100000  // maskCommand
        case .rightControl:             return 0x00040000  // maskControl
        case .fn:                       return 0x00800000  // maskSecondaryFn
        }
    }
}
