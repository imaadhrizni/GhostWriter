import SwiftUI
import ServiceManagement
import UniformTypeIdentifiers

// MARK: - Window Controller

final class SettingsWindowController: NSWindowController {
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.center()
        window.title = "GhostWriter Settings"
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        // Remember a resized/dragged window so the sidebar width sticks.
        window.setFrameAutosaveName("SettingsWindow")

        self.init(window: window)

        let contentView = NSHostingView(rootView: SettingsView())
        window.contentView = contentView
    }

    func showAndActivate() {
        window?.center()
        bringToFront()
    }
}

// MARK: - Sections

private enum SettingsSection: String, CaseIterable, Identifiable {
    case essentials  = "Essentials"
    case general     = "General"
    case ai          = "AI & Models"
    case dictation   = "Dictation"
    case styles      = "Writing Styles"
    case quickNotes  = "Quick Notes"
    case meeting     = "Recording"
    case notes       = "Notes & Summaries"
    case meetingTemplates = "Meeting Templates"
    case draftTemplates = "Draft Templates"
    case digest      = "Digest"
    case privacy     = "Privacy"
    case permissions = "Permissions"
    case shortcuts   = "Shortcuts"
    case integrations = "Integrations"
    case stats       = "Usage & Cost"
    case diagnostics = "Diagnostics"
    case about       = "About"

    var id: String { rawValue }

    /// Sidebar layout: related panes grouped under headers, the way
    /// System Settings clusters its domains.
    static let sidebarGroups: [(title: String?, sections: [SettingsSection])] = [
        (nil,                  [.essentials, .general, .ai]),
        ("Capture",            [.dictation, .styles, .quickNotes]),
        ("Meetings",           [.meeting, .notes, .meetingTemplates, .draftTemplates]),
        // Digest + hooks are both scheduled/outbound automation, not meeting capture.
        ("Automation",         [.digest, .integrations]),
        ("Privacy & Security", [.privacy, .permissions]),
        ("System",             [.shortcuts, .diagnostics]),
        // Usage/cost is account-scoped; About folds in here rather than a lone group.
        ("Account",            [.stats, .about]),
    ]

    var icon: String {
        switch self {
        case .essentials:  return "sparkles"
        case .general:     return "gearshape.fill"
        case .ai:          return "cpu.fill"
        case .dictation:   return "mic.fill"
        case .styles:      return "textformat"
        case .quickNotes:  return "square.and.pencil"
        case .meeting:     return "person.2.wave.2.fill"
        case .notes:       return "doc.text.fill"
        case .meetingTemplates: return "doc.on.doc.fill"
        case .draftTemplates: return "doc.badge.gearshape"
        case .digest:      return "newspaper.fill"
        case .privacy:     return "hand.raised.fill"
        case .permissions: return "lock.shield.fill"
        case .shortcuts:   return "command"
        case .integrations: return "bolt.horizontal.circle.fill"
        case .stats:       return "chart.bar.fill"
        case .diagnostics: return "stethoscope"
        case .about:       return "info.circle.fill"
        }
    }

    var iconColor: Color {
        switch self {
        case .essentials:  return .accentColor
        case .general:     return .gray
        case .ai:          return .mint
        case .dictation:   return .blue
        case .styles:      return .cyan
        case .quickNotes:  return .yellow
        case .meeting:     return .purple
        case .notes:       return .indigo
        case .meetingTemplates: return .teal
        case .draftTemplates: return .teal
        case .digest:      return .brown
        case .privacy:     return .pink
        case .permissions: return .green
        case .shortcuts:   return .orange
        case .integrations: return .indigo
        case .stats:       return .teal
        case .diagnostics: return .red
        case .about:       return .secondary
        }
    }
}

// MARK: - Global Settings Search

/// One searchable setting, mapped to the pane that hosts it. The index is
/// curated (rather than reflected from the views) so results stay meaningful
/// and stable: `label` is what the user reads, `keywords` widen the match to
/// synonyms and adjacent terms the label doesn't contain.
fileprivate struct SettingsSearchEntry: Identifiable {
    let label: String
    let section: SettingsSection
    let keywords: [String]
    var id: String { "\(section.rawValue)·\(label)" }

    /// True if every whitespace-separated token of `query` appears in the
    /// label, the section name, or any keyword (all case-insensitive).
    func matches(_ query: String) -> Bool {
        let haystack = ([label, section.rawValue] + keywords)
            .joined(separator: " ").lowercased()
        let tokens = query.lowercased().split(separator: " ")
        return tokens.allSatisfy { haystack.contains($0) }
    }
}

fileprivate enum SettingsSearchIndex {
    // Cross-cutting action vocabulary. Almost every field pane carries an
    // inline "reset to default" affordance (DefaultResetButton), so a bare
    // "reset" / "default" / "restore" query should surface those panes rather
    // than returning nothing. Sections listed here get a synthetic action row.
    static let resettableSections: [SettingsSection] =
        [.general, .ai, .dictation, .quickNotes, .meeting, .notes, .digest, .shortcuts]

    static let all: [SettingsSearchEntry] = [
        // Essentials
        .init(label: "Getting started / setup checklist", section: .essentials, keywords: ["onboarding", "first run", "essentials", "setup", "get started", "welcome", "readiness", "api key", "permissions"]),
        // General
        .init(label: "Launch at login", section: .general, keywords: ["startup", "boot", "open at login", "autostart", "default", "reset"]),
        .init(label: "Notes folder location", section: .general, keywords: ["storage", "save", "directory", "path", "choose", "change", "default", "reset"]),
        .init(label: "Back up & restore notes", section: .general, keywords: ["backup", "restore", "export", "import", "archive", "recover"]),
        .init(label: "Automatic backups", section: .general, keywords: ["automatic", "auto backup", "daily", "retention", "keep", "schedule", "back up now", "snapshot", "last backup", "recover"]),
        .init(label: "Talk-time analytics", section: .notes, keywords: ["talk time", "engagement", "talk share", "who spoke", "turns", "questions", "monologue", "analytics", "diarization"]),
        .init(label: "Objections & competitors", section: .notes, keywords: ["objection", "competitor", "competition", "incumbent", "pushback", "concern", "blocker", "sales intelligence", "compete", "rival"]),
        .init(label: "Agentic Ask", section: .notes, keywords: ["ask", "agentic", "knowledge base", "everything", "search", "query planning", "catalog facts", "ask anything"]),
        .init(label: "Date format", section: .general, keywords: ["timestamp", "filename", "default", "reset"]),
        .init(label: "PDF paper size (Letter / A4)", section: .general, keywords: ["pdf", "export", "paper", "a4", "letter", "page size", "print", "report", "poc"]),
        .init(label: "Menu-bar icon", section: .general, keywords: ["status item", "tray", "default", "reset"]),
        // AI & Models
        .init(label: "Groq API key", section: .ai, keywords: ["token", "account", "authentication", "credential", "change", "clear", "remove"]),
        .init(label: "Transcription model", section: .ai, keywords: ["whisper", "speech to text", "stt", "default", "reset"]),
        .init(label: "Polishing model", section: .ai, keywords: ["llama", "qwen", "summaries", "llm", "chat", "default", "reset"]),
        .init(label: "Lightweight-tasks model", section: .ai, keywords: ["fast", "cheap", "background", "live brief", "default", "reset"]),
        .init(label: "Transcription language", section: .ai, keywords: ["iso", "locale", "tamil", "sinhala", "german", "spanish", "auto-detect", "auto detect", "picker", "default", "reset"]),
        .init(label: "API endpoint (advanced)", section: .ai, keywords: ["base url", "endpoint", "proxy", "gateway", "self-hosted", "openai-compatible", "groq", "provider"]),
        .init(label: "Offline fallback", section: .ai, keywords: ["on-device", "apple", "no network", "private"]),
        .init(label: "Prefer on-device AI", section: .ai, keywords: ["apple intelligence", "private", "local llm"]),
        // Dictation
        .init(label: "Dictation hotkey", section: .dictation, keywords: ["shortcut", "push to talk", "trigger", "default", "reset"]),
        .init(label: "Activation (hold / tap-to-lock / toggle)", section: .dictation, keywords: ["hands-free", "hands free", "toggle", "tap to lock", "latch", "hold", "long dictation", "push to talk", "ptt"]),
        .init(label: "Skip silent recordings", section: .dictation, keywords: ["silence", "silent", "vad", "voice activity", "threshold", "dbfs", "noise gate", "skip", "save api", "hallucination"]),
        .init(label: "Audio import (max size)", section: .dictation, keywords: ["import", "transcribe file", "audio file", "wav", "mp3", "ogg", "opus", "m4a", "drag drop", "voice note", "chat"]),
        .init(label: "Voice commands", section: .styles, keywords: ["dictation commands", "new paragraph", "scratch that", "phrase", "effect", "rules"]),
        .init(label: "Per-app style overrides", section: .styles, keywords: ["app", "bundle id", "override", "force style", "slack", "vscode", "per app", "custom style"]),
        .init(label: "Text insertion (paste-only apps)", section: .styles, keywords: ["paste", "clipboard", "inject", "not working", "electron", "chromium", "claude", "slack", "vscode", "discord", "cursor", "no text", "missing text", "cmd v"]),
        // Writing styles
        .init(label: "Writing styles", section: .styles, keywords: ["tone", "prompt", "rewrite", "voice", "custom style"]),
        .init(label: "Add or delete a writing style", section: .styles, keywords: ["new", "remove", "delete", "create", "edit"]),
        // Quick notes
        .init(label: "Quick note hotkey", section: .quickNotes, keywords: ["shortcut", "capture", "default", "reset"]),
        // Recording
        .init(label: "Meeting audio source", section: .meeting, keywords: ["microphone", "system audio", "input device", "default", "reset"]),
        .init(label: "Live brief", section: .meeting, keywords: ["real-time", "assistant", "coaching", "agenda coverage", "refresh interval", "during the meeting"]),
        .init(label: "Prep card on start", section: .meeting, keywords: ["prep", "recent notes", "linked", "org", "project", "during the meeting"]),
        .init(label: "Meeting templates", section: .meetingTemplates, keywords: ["agenda", "type", "prep", "add", "delete", "default", "sections", "follow-up"]),
        .init(label: "Import / export templates", section: .meetingTemplates, keywords: ["backup", "share", "bundle", "json", "house style", "merge", "replace"]),
        .init(label: "Per-app recording overrides", section: .meeting, keywords: ["app", "override", "delete", "remove", "default", "unrecognized"]),
        .init(label: "Auto-detect poll interval", section: .meeting, keywords: ["advanced", "detection", "poll", "interval", "how often", "call detection", "timing"]),
        .init(label: "Meeting-end sensitivity", section: .meeting, keywords: ["advanced", "end", "quiet", "polls", "detection", "hang up", "timing"]),
        .init(label: "Transcription request timeout", section: .meeting, keywords: ["advanced", "timeout", "groq", "network", "seconds", "retry", "stt"]),
        .init(label: "Audio-import request timeout", section: .meeting, keywords: ["advanced", "timeout", "import", "file", "upload", "seconds", "stt"]),
        .init(label: "Live-brief refresh threshold", section: .meeting, keywords: ["advanced", "growth", "chars", "brief", "refresh", "how much"]),
        .init(label: "Summary context budget", section: .meeting, keywords: ["advanced", "summary", "context", "tokens", "chars", "budget", "length", "ai"]),
        .init(label: "Push-to-talk tap threshold", section: .dictation, keywords: ["tap", "hold", "lock", "threshold", "latch", "hands-free", "ptt", "timing"]),
        .init(label: "Remap global shortcuts", section: .shortcuts, keywords: ["hotkey", "shortcut", "rebind", "remap", "keybinding", "customize keys", "control option", "⌃⌥", "meeting", "quick note", "bookmark", "conflict"]),
        // Notes & summaries
        .init(label: "Auto-title notes", section: .notes, keywords: ["heading", "name", "smart title"]),
        .init(label: "Summary generation", section: .notes, keywords: ["recap", "overview", "abstract"]),
        .init(label: "Unanswered questions", section: .notes, keywords: ["follow-up", "open items", "action"]),
        .init(label: "Entity tags", section: .notes, keywords: ["people", "org", "topics", "auto-tag"]),
        .init(label: "Chapters", section: .notes, keywords: ["sections", "timestamps", "outline"]),
        .init(label: "Reset note prompts to default", section: .notes, keywords: ["default", "reset", "prompt", "restore"]),
        // Draft templates
        .init(label: "Draft templates", section: .draftTemplates, keywords: ["follow-up email", "reply", "message", "add", "delete", "reset to default"]),
        .init(label: "Follow-Up Packet", section: .draftTemplates, keywords: ["packet", "bundle", "one-click", "poc plan", "action items", "follow-up email", "sections", "reorder", "order", "confirm", "ai usage", "cloud"]),
        // Digest
        .init(label: "Relationship digest", section: .digest, keywords: ["daily", "weekly", "summary email", "rollup", "default", "reset"]),
        // Privacy
        .init(label: "Local-only mode", section: .privacy, keywords: ["offline", "no cloud", "private", "network"]),
        .init(label: "Data retention", section: .privacy, keywords: ["delete", "history", "purge", "clear", "remove"]),
        // Permissions
        .init(label: "Microphone permission", section: .permissions, keywords: ["access", "privacy", "tcc"]),
        .init(label: "Accessibility permission", section: .permissions, keywords: ["auto-paste", "keystroke", "tcc"]),
        .init(label: "Screen recording permission", section: .permissions, keywords: ["system audio", "capture"]),
        // Shortcuts
        .init(label: "Keyboard shortcuts", section: .shortcuts, keywords: ["hotkeys", "bindings", "keys", "reset", "default", "clear"]),
        // Usage & cost
        .init(label: "Usage & cost", section: .stats, keywords: ["spend", "tokens", "billing", "minutes", "statistics"]),
        .init(label: "Clear usage statistics", section: .stats, keywords: ["reset", "clear", "delete", "wipe", "history"]),
        // Integrations
        .init(label: "Meeting-finished webhook", section: .integrations, keywords: ["http", "post", "zapier", "slack", "notion", "event", "hook", "url"]),
        .init(label: "Local script hook", section: .integrations, keywords: ["shell", "script", "automation", "event", "stdin", "run"]),
        // Diagnostics
        .init(label: "Diagnostics & logs", section: .diagnostics, keywords: ["debug", "troubleshoot", "console"]),
        .init(label: "Export logs", section: .diagnostics, keywords: ["save", "share", "report", "clear logs"]),
        // About
        .init(label: "Version & updates", section: .about, keywords: ["build", "changelog", "credits"]),
    ]

    static func results(for query: String) -> [SettingsSearchEntry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        var hits = all.filter { $0.matches(q) }

        // Bare action words (reset / default / restore) apply to nearly every
        // field pane. Add a synthetic row for each resettable pane not already
        // surfaced, so the user can jump to the pane and use its inline reset.
        let lower = q.lowercased()
        let isResetQuery = ["reset", "default", "defaults", "restore"].contains { lower.contains($0) }
        if isResetQuery {
            let already = Set(hits.map(\.section))
            for section in resettableSections where !already.contains(section) {
                hits.append(.init(label: "Reset \(section.rawValue) to defaults",
                                  section: section, keywords: []))
            }
        }
        return hits
    }
}

// MARK: - Settings Root (System Settings-style sidebar)

/// A macOS switch toggle sized small. Scoping `.controlSize(.small)` inside the
/// style keeps it to toggles only, so labels, popups, and fields stay regular.
private struct SmallSwitchToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer()
            Toggle("", isOn: configuration.$isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .scaleEffect(0.8, anchor: .trailing)
        }
    }
}

struct SettingsView: View {
    @State private var selection: SettingsSection = .essentials
    @State private var searchText = ""

    private func sidebarRow(_ section: SettingsSection) -> some View {
        Label {
            Text(section.rawValue)
        } icon: {
            Image(systemName: section.icon)
                .foregroundColor(.white)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 5).fill(section.iconColor))
        }
        .tag(section)
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                    ForEach(SettingsSection.sidebarGroups, id: \.title) { group in
                        Section {
                            ForEach(group.sections) { section in
                                sidebarRow(section)
                            }
                        } header: {
                            if let title = group.title { Text(title) }
                        }
                    }
                } else {
                    let results = SettingsSearchIndex.results(for: searchText)
                    if results.isEmpty {
                        Text("No settings match “\(searchText)”")
                            .font(.callout).foregroundColor(.secondary)
                            .padding(.vertical, 8)
                    } else {
                        Section("Results") {
                            ForEach(results) { entry in
                                Button {
                                    selection = entry.section
                                    searchText = ""
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: entry.section.icon)
                                            .foregroundColor(.white)
                                            .frame(width: 20, height: 20)
                                            .background(RoundedRectangle(cornerRadius: 5).fill(entry.section.iconColor))
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(entry.label)
                                            Text(entry.section.rawValue)
                                                .font(.caption2).foregroundColor(.secondary)
                                        }
                                        Spacer(minLength: 0)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 215, ideal: 235, max: 300)
            .searchable(text: $searchText, placement: .sidebar, prompt: "Search settings")
        } detail: {
            ScrollView {
                Group {
                    switch selection {
                    case .essentials:  EssentialsPane(navigate: { selection = $0 })
                    case .general:     GeneralPane()
                    case .ai:          AIPane()
                    case .dictation:   DictationPane()
                    case .styles:      WritingStylesPane()
                    case .quickNotes:  QuickNotesPane()
                    case .meeting:     MeetingPane()
                    case .notes:       MeetingNotesPane()
                    case .meetingTemplates: MeetingTemplatesPane()
                    case .draftTemplates: DraftTemplatesPane()
                    case .digest:      DigestPane()
                    case .privacy:     PrivacyPane()
                    case .permissions: PermissionsPane()
                    case .shortcuts:   ShortcutsPane()
                    case .integrations: IntegrationsPane()
                    case .stats:       StatsPane()
                    case .diagnostics: DiagnosticsPane()
                    case .about:       AboutPane()
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(selection.rawValue)
        }
        .frame(minWidth: 760, idealWidth: 760, minHeight: 520, idealHeight: 520)
        // Use macOS switches for every Toggle in Settings (cascades to all panes),
        // sized small so they sit proportionally next to labels and fields.
        .toggleStyle(SmallSwitchToggleStyle())
    }
}

// MARK: - Essentials (first-run / at-a-glance readiness)

/// The landing pane: a live readiness checklist of the few things that must be
/// set up before GhostWriter works, plus a reminder of the main dictation
/// gesture. Every row deep-links into the pane that owns the full controls, so
/// this stays a *dashboard*, not a duplicate settings surface.
private struct EssentialsPane: View {
    let navigate: (SettingsSection) -> Void

    @ObservedObject private var settings = AppSettings.shared
    private let permissionGuard = PermissionGuard()

    @State private var hasAPIKey = KeychainService.groqAPIKey() != nil
    @State private var hasMic = false
    @State private var hasA11y = false

    /// The hard requirements for the app to function at all.
    private var readyCount: Int { [hasAPIKey, hasMic, hasA11y].filter { $0 }.count }
    private var allReady: Bool { readyCount == 3 }

    private var pttKeyName: String {
        (PTTKey(rawValue: settings.pttKeyCode) ?? .rightOption).displayName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            banner

            SettingsGroup("Set Up") {
                ChecklistRow(
                    done: hasAPIKey,
                    title: "Connect your Groq API key",
                    detail: hasAPIKey ? "API key configured." : "Required for transcription and AI summaries.",
                    actionTitle: hasAPIKey ? "Change…" : "Set Up…"
                ) { NotificationCenter.default.post(name: .showAPIKeyWindow, object: nil) }

                Divider()

                ChecklistRow(
                    done: hasMic,
                    title: "Grant Microphone access",
                    detail: hasMic ? "Granted." : "Required to hear your voice and meetings.",
                    actionTitle: hasMic ? "Manage…" : "Grant…"
                ) { navigate(.permissions) }

                Divider()

                ChecklistRow(
                    done: hasA11y,
                    title: "Grant Accessibility access",
                    detail: hasA11y ? "Granted." : "Required for the push-to-talk key and typing at your cursor.",
                    actionTitle: hasA11y ? "Manage…" : "Grant…"
                ) { navigate(.permissions) }
            }

            SettingsGroup("How to Dictate") {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "mic.fill")
                        .foregroundColor(.blue)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(dictationSummary)
                        Text("Place your cursor in any text field, in any app, then use the key above. Esc cancels.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button("Configure…") { navigate(.dictation) }
                }
            }

            SettingsGroup("Where Notes Are Saved") {
                HStack {
                    Image(systemName: "folder.fill")
                        .foregroundColor(.indigo)
                        .frame(width: 20)
                    Text(settings.notesFolder.path.abbreviatingHome())
                        .font(.callout).foregroundColor(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Button("Change…") { navigate(.notes) }
                }
            }

            Text("This page just links to the full settings — explore the sidebar for meetings, styles, privacy, and more.")
                .font(.caption).foregroundColor(.secondary)
        }
        .onAppear(perform: refresh)
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in refresh() }
    }

    private var dictationSummary: String {
        switch settings.pttActivation {
        case .hold:    return "Hold \(pttKeyName) to record, release to type."
        case .tapLock: return "Tap \(pttKeyName) to lock hands-free (or hold for a quick phrase)."
        case .toggle:  return "Press \(pttKeyName) to start, press again to stop."
        }
    }

    @ViewBuilder private var banner: some View {
        HStack(spacing: 10) {
            Image(systemName: allReady ? "checkmark.seal.fill" : "sparkles")
                .font(.title2)
                .foregroundColor(allReady ? .green : .accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(allReady ? "You're all set." : "Welcome to GhostWriter")
                    .font(.headline)
                Text(allReady
                     ? "Everything's connected — you're ready to dictate and record meetings."
                     : "\(3 - readyCount) of 3 setup steps left before you can start.")
                    .font(.caption).foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill((allReady ? Color.green : Color.accentColor).opacity(0.10)))
    }

    private func refresh() {
        hasAPIKey = KeychainService.groqAPIKey() != nil
        hasMic = permissionGuard.hasMicrophonePermission
        hasA11y = permissionGuard.hasAccessibilityPermission
    }
}

/// A setup-step row: a status glyph, a title + detail, and a trailing action.
private struct ChecklistRow: View {
    let done: Bool
    let title: String
    let detail: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundColor(done ? .green : .orange)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundColor(.secondary)
            }
            Spacer(minLength: 8)
            Button(actionTitle, action: action)
        }
    }
}

// MARK: - General

private struct AIPane: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var hasAPIKey = KeychainService.groqAPIKey() != nil

    private static let transcriptionModels = [
        "whisper-large-v3",
        "whisper-large-v3-turbo",
        "distil-whisper-large-v3-en",
    ]
    private static let polishingModels = [
        "llama-3.3-70b-versatile",                      // non-reasoning, plain Markdown — default
        "llama-3.1-8b-instant",
        "openai/gpt-oss-120b",                          // reasoning model (answer arrives via the reasoning field)
        "openai/gpt-oss-20b",
    ]

    /// Common Whisper-supported languages for the picker. Empty code = auto-detect
    /// (no `language` param sent, so Whisper identifies it per recording).
    private static let transcriptionLanguages: [(code: String, name: String)] = [
        ("",   "Auto-detect"),
        ("en", "English"),   ("es", "Spanish"),    ("fr", "French"),
        ("de", "German"),    ("it", "Italian"),    ("pt", "Portuguese"),
        ("nl", "Dutch"),     ("ru", "Russian"),    ("zh", "Chinese"),
        ("ja", "Japanese"),  ("ko", "Korean"),     ("hi", "Hindi"),
        ("ar", "Arabic"),    ("ta", "Tamil"),      ("si", "Sinhala"),
        ("bn", "Bengali"),   ("tr", "Turkish"),    ("pl", "Polish"),
        ("uk", "Ukrainian"), ("id", "Indonesian"), ("vi", "Vietnamese"),
    ]

    /// The language options, ensuring the currently-stored code is always present
    /// (an unrecognized custom ISO code shows as "<code> (custom)").
    private static func transcriptionLanguageOptions(including current: String)
        -> [(code: String, name: String)] {
        var opts = transcriptionLanguages
        if !current.isEmpty && !opts.contains(where: { $0.code == current }) {
            opts.append((current, "\(current) (custom)"))
        }
        return opts
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsGroup("Groq Account") {
                HStack {
                    Image(systemName: hasAPIKey ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundColor(hasAPIKey ? .green : .orange)
                    Text(hasAPIKey ? "API key configured" : "No API key set")
                    Spacer()
                    Button("Change…") {
                        NotificationCenter.default.post(name: .showAPIKeyWindow, object: nil)
                    }
                }

                DisclosureGroup("Advanced — API endpoint") {
                    HStack {
                        TextField(AppSettings.Default.apiBaseURL, text: $settings.apiBaseURL)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.caption, design: .monospaced))
                        DefaultResetButton(isDefault: settings.apiBaseURL == AppSettings.Default.apiBaseURL) {
                            settings.apiBaseURL = AppSettings.Default.apiBaseURL
                        }
                    }
                    Text("OpenAI-compatible base URL used for transcription, chat, and the model catalog. Change only to route through a proxy, an enterprise gateway, or a self-hosted OpenAI-compatible server. Blank resets to Groq.")
                        .font(.caption).foregroundColor(.secondary)
                }
            }

            SettingsGroup("Models") {
                ModelField(
                    title: "Transcription model",
                    presets: Self.transcriptionModels,
                    defaultValue: AppSettings.Default.transcriptionModel,
                    value: $settings.transcriptionModel
                )

                Divider()

                HStack {
                    Text("Language")
                    Spacer()
                    Picker("", selection: $settings.transcriptionLanguage) {
                        ForEach(Self.transcriptionLanguageOptions(including: settings.transcriptionLanguage), id: \.code) { opt in
                            Text(opt.name).tag(opt.code)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                    DefaultResetButton(isDefault: settings.transcriptionLanguage == AppSettings.Default.transcriptionLanguage) {
                        settings.transcriptionLanguage = AppSettings.Default.transcriptionLanguage
                    }
                }
                Text("Spoken-language hint for Whisper — applies to both dictation and meetings. Auto-detect lets Whisper identify the language per recording; pick a specific language for best accuracy if you always speak one.")
                    .font(.caption).foregroundColor(.secondary)

                Divider()

                ModelField(
                    title: "Polishing model",
                    presets: Self.polishingModels,
                    defaultValue: AppSettings.Default.polishingModel,
                    value: $settings.polishingModel
                )

                Divider()

                ModelField(
                    title: "Lightweight-tasks model",
                    presets: Self.polishingModels,
                    defaultValue: AppSettings.Default.fastModel,
                    value: $settings.fastModel
                )
                Text("A cheaper, faster model for high-frequency background work — the live brief, agenda coverage, auto-tagging, and search-term expansion. Summaries, follow-ups, and Ask use the polishing model above.")
                    .font(.caption).foregroundColor(.secondary)
            }

            SettingsGroup("Model Availability") {
                ModelAvailabilityView()
                Text("Groq adds and retires models over time. Each choice above is checked against Groq's live catalog; an unavailable one is routed to the best working replacement automatically until you pick another.")
                    .font(.caption).foregroundColor(.secondary)
            }

            SettingsGroup("On-Device & Fallback") {
                Toggle("Offline fallback (Apple on-device recognition)", isOn: $settings.offlineFallback)
                Text("If Groq can't be reached, transcribe on-device instead of failing — applies to dictation, quick notes, and meetings. Lower accuracy and no AI polishing or summaries (transcription only), but zero network. Triggers on connectivity errors, not on API-key or server errors.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Divider()

                Toggle("Prefer on-device AI for summaries & drafts", isOn: $settings.preferOnDeviceAI)
                    .disabled(!AppleIntelligence.isAvailable)
                Text("Generate note summaries, relationship digests, and follow-up drafts with Apple Intelligence instead of Groq — keeping Groq for transcription. Private and free; falls back to Groq if the on-device model isn't available. Groq still handles the live brief, auto-tags, and Ask.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                if !AppleIntelligence.isAvailable {
                    Label(AppleIntelligence.unavailableReason ?? "Apple Intelligence is unavailable on this Mac.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundColor(.orange)
                }
            }
        }
        .onAppear { hasAPIKey = KeychainService.groqAPIKey() != nil }
    }
}

private struct GeneralPane: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    /// Registers/unregisters the app as a macOS login item. The system stores
    /// this (System Settings → General → Login Items), so there is no
    /// UserDefaults setting to keep in sync — status is re-read on appear.
    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.app.error("❌ Login item change failed: \(error.localizedDescription)")
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsGroup("Notes") {
                Toggle("Open notes in external editor", isOn: $settings.openNotesExternally)
                Text("Open note files in your default Markdown app (e.g. VS Code, Obsidian, Typora) instead of the in-app viewer — everywhere notes open: the menu, recent list, Catalog, and Ask. Set your preferred app in Finder → a .md file → Get Info → Open with → Change All. Off uses the built-in viewer.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            SettingsGroup("Microphone") {
                Toggle("Prefer built-in microphone", isOn: $settings.preferBuiltInMic)
                Text("Off: capture from the system default input (e.g. your headset mic). On: always use the Mac's built-in mic — keeps Bluetooth headphones (AirPods) in high-quality audio, since using their mic forces the low-quality call profile and shifts volume. Applies to dictation and meetings.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            SettingsGroup("Display") {
                DateFormatField()
            }

            SettingsGroup("PDF Export") {
                Picker("Paper size", selection: $settings.pdfPaperSize) {
                    Text("US Letter").tag("letter")
                    Text("A4").tag("a4")
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)
                Text("Page size for exported PDFs — meeting notes, Reports, and POCs. A4 is the standard outside North America.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            SettingsGroup("Startup") {
                Toggle("Start GhostWriter at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        setLaunchAtLogin(enabled)
                    }
                Text("Automatically open GhostWriter in the menu bar when you log in to your Mac.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            SettingsGroup("Backup") {
                BackupRow()
            }

            SettingsGroup("Automatic Backups") {
                AutomaticBackupRow()
            }

            SettingsGroup("Maintenance") {
                ResetToDefaultsRow()
            }
        }
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

/// Full-app backup: one zip of meeting notes, quick notes, dictations, and the
/// Catalog — plus a merging restore. Lives in General because it spans every
/// data folder, not just one feature.
private struct BackupRow: View {
    @State private var status = ""
    @State private var confirmRestore = false
    @State private var pendingArchive: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Save everything GhostWriter stores — meeting notes, quick notes, dictations, and the Catalog — as a single `.zip` you can archive or move to another Mac. Restore merges a backup back in; your existing files with the same name are overwritten.")
                .font(.caption)
                .foregroundColor(.secondary)
            HStack {
                Button { backUp() } label: {
                    Label("Back Up…", systemImage: "square.and.arrow.up.on.square")
                }
                Button { pickRestore() } label: {
                    Label("Restore…", systemImage: "square.and.arrow.down.on.square")
                }
                Spacer()
                if !status.isEmpty {
                    Text(status).font(.caption).foregroundColor(.secondary)
                }
            }
        }
        .confirmationDialog("Restore from backup?", isPresented: $confirmRestore, titleVisibility: .visible) {
            Button("Restore", role: .destructive) { runRestore() }
            Button("Cancel", role: .cancel) { pendingArchive = nil }
        } message: {
            Text("Files from the backup are merged into your current notes, quick notes, dictations, and Catalog. Existing files with the same name are overwritten. This can't be undone.")
        }
    }

    private func backUp() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "GhostWriter-Backup.zip"
        panel.prompt = "Back Up"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try BackupService.createBackup(to: url)
            status = "Backed up"
        } catch {
            status = error.localizedDescription
        }
    }

    private func pickRestore() {
        guard let url = FilePanels.openFile(contentTypes: [.zip], prompt: "Restore") else { return }
        pendingArchive = url
        confirmRestore = true
    }

    private func runRestore() {
        guard let archive = pendingArchive else { return }
        pendingArchive = nil
        do {
            let s = try BackupService.restoreBackup(from: archive)
            CatalogStore.shared.load()          // pick up the restored Catalog.json
            _ = CatalogStore.shared.indexNotesFolder()
            CatalogStore.shared.refresh()
            var parts: [String] = []
            if s.notes { parts.append("notes") }
            if s.quickNotes { parts.append("quick notes") }
            if s.dictations { parts.append("dictations") }
            status = parts.isEmpty ? "Nothing to restore" : "Restored \(parts.joined(separator: ", "))"
        } catch {
            status = error.localizedDescription
        }
    }
}

/// Unattended daily snapshots: a dated `.zip` written once per day, keeping only
/// the most recent few. Opportunistic (runs the first awake hour on a new day),
/// so a Mac asleep at midnight still gets backed up.
private struct AutomaticBackupRow: View {
    @ObservedObject private var settings = AppSettings.shared

    /// Bumped when a backup completes so the marker line re-reads the store.
    @State private var completionTick = 0
    @State private var isBackingUp = false

    private var lastBackupText: String {
        _ = completionTick
        guard let last = settings.lastAutomaticBackupAt else { return "No automatic backup yet" }
        let kept = BackupService.automaticArchives(in: settings.autoBackupFolder).count
        return "Last backup: \(DateDisplay.relativeDateTime(last)) · \(kept) kept"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Back up automatically once a day", isOn: $settings.autoBackupEnabled)
            Text("Once a day, GhostWriter saves a dated `.zip` of everything it stores into a private folder, keeping only the most recent copies. It runs the first time the app is awake on a new day, so a Mac that slept overnight isn't skipped, and never during a live meeting.")
                .font(.caption)
                .foregroundColor(.secondary)

            if settings.autoBackupEnabled {
                Stepper(value: $settings.autoBackupRetentionDays, in: 1...30) {
                    Text("Keep the last \(settings.autoBackupRetentionDays) day\(settings.autoBackupRetentionDays == 1 ? "" : "s")")
                }
                .frame(maxWidth: 320, alignment: .leading)

                HStack(spacing: 6) {
                    Text("Folder:").foregroundColor(.secondary)
                    Text(settings.autoBackupFolder.path)
                        .lineLimit(1).truncationMode(.middle)
                        .help(settings.autoBackupFolder.path)
                    Button("Change…") { changeFolder() }
                    Button("Reveal") {
                        NSWorkspace.shared.activateFileViewerSelecting([settings.autoBackupFolder])
                    }
                }
                .font(.caption)

                HStack {
                    Button {
                        isBackingUp = true
                        BackupService.runAutomaticBackup()
                    } label: {
                        Label("Back Up Now", systemImage: "clock.arrow.circlepath")
                    }
                    .disabled(isBackingUp)
                    Spacer()
                    Text(lastBackupText).font(.caption).foregroundColor(.secondary)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: BackupService.automaticBackupDidComplete)) { _ in
            isBackingUp = false
            completionTick += 1
        }
    }

    private func changeFolder() {
        guard let url = FilePanels.openFolder(directory: settings.autoBackupFolder,
                                              prompt: "Choose Backup Folder") else { return }
        settings.autoBackupFolder = url
    }
}

/// Editable model name with a preset menu and reset-to-default.
private struct ModelField: View {
    let title: String
    let presets: [String]
    let defaultValue: String
    @Binding var value: String

    /// Bumped once the live catalog is fetched, so the availability note
    /// re-evaluates. ModelResolver isn't observable, hence the manual tick.
    @State private var catalogTick = 0

    /// True only when we have a catalog AND it doesn't contain the chosen id —
    /// so we never warn just because the catalog hasn't loaded yet.
    private var unavailable: Bool {
        _ = catalogTick
        let id = value.trimmingCharacters(in: .whitespaces)
        return ModelResolver.shared.hasCatalog && !id.isEmpty && !ModelResolver.shared.isAvailable(id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                TextField("", text: $value)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 230)
                    .multilineTextAlignment(.trailing)
                Menu {
                    ForEach(presets, id: \.self) { preset in
                        Button(preset) { value = preset }
                    }
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24)
                DefaultResetButton(isDefault: value == defaultValue) { value = defaultValue }
            }
            if unavailable {
                Label("Not in Groq's current model list — a working model is used automatically until you pick another.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundColor(.orange)
            }
        }
        .task {
            await ModelResolver.shared.refresh()
            catalogTick += 1
        }
    }
}

/// Live view of how each configured model resolves against Groq's catalog:
/// catalog freshness, a manual refresh, and a per-role configured→resolved row
/// badged ✓ available / ⚠ substituted.
private struct ModelAvailabilityView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var tick = 0
    @State private var refreshing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                let count = ModelResolver.shared.catalogCount
                Text(count > 0 ? "\(count) models in catalog" : "Catalog not loaded yet")
                    .font(.caption).foregroundColor(.secondary)
                if let d = ModelResolver.shared.lastFetched {
                    Text("· checked \(d.formatted(.relative(presentation: .named)))")
                        .font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Button { refresh() } label: {
                    if refreshing { ProgressView().controlSize(.small) } else { Text("Refresh") }
                }
                .disabled(refreshing)
            }
            row("Transcription", .transcription, settings.transcriptionModel)
            row("Polishing", .summary, settings.polishingModel)
            row("Lightweight", .lightweight, settings.fastModel)
        }
        .id(tick)
        .task { await ModelResolver.shared.refresh(); tick += 1 }
    }

    @ViewBuilder
    private func row(_ label: String, _ role: ModelResolver.Role, _ configured: String) -> some View {
        let ok = !ModelResolver.shared.hasCatalog || ModelResolver.shared.isAvailable(configured)
        let resolved = ModelResolver.shared.resolve(role, configured: configured)
        HStack(spacing: 6) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundColor(ok ? .green : .orange)
            Text(label).frame(width: 92, alignment: .leading)
            Text(ok ? configured : "\(configured) → \(resolved)")
                .font(.caption).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
            Spacer()
        }
    }

    private func refresh() {
        refreshing = true
        Task { await ModelResolver.shared.refresh(force: true); refreshing = false; tick += 1 }
    }
}

/// Live readout of the shared AIGate: in-flight/queued requests per lane and
/// any rate-limit backoff. Polls the actor while the pane is visible.
struct AIActivityView: View {
    @State private var snap: AIGate.Snapshot?

    var body: some View {
        Group {
            if let s = snap {
                StatRow(label: "Chat requests",
                        value: "\(s.chatActive)/\(s.chatCap) in flight" + (s.chatWaiting > 0 ? " · \(s.chatWaiting) queued" : ""))
                StatRow(label: "Transcription requests",
                        value: "\(s.transcriptionActive)/\(s.transcriptionCap) in flight" + (s.transcriptionWaiting > 0 ? " · \(s.transcriptionWaiting) queued" : ""))
                if s.pausedFor > 0 {
                    Label("Rate-limited — backing off ~\(Int(s.pausedFor.rounded()))s", systemImage: "clock.badge.exclamationmark")
                        .font(.caption).foregroundColor(.orange)
                } else {
                    Text("No rate-limit backoff active.").font(.caption).foregroundColor(.secondary)
                }
            } else {
                Text("Reading…").font(.caption).foregroundColor(.secondary)
            }
        }
        .task {
            while !Task.isCancelled {
                snap = await AIGate.shared.snapshot()
                try? await Task.sleep(nanoseconds: 1_200_000_000)
            }
        }
    }
}

/// Compact summary of the per-call API log with a button to the full window.
struct APICallLogSummary: View {
    @State private var count = 0
    @State private var cost = 0.0

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(count > 0 ? "\(count) calls logged" : "No calls logged yet")
                Text("\(UsageStats.currency(cost)) estimated across logged calls")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open Full Log…") { APIUsageLogWindowController.present() }
        }
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: APIUsageLog.didLog)) { _ in reload() }
    }

    private func reload() {
        let e = APIUsageLog.shared.entries
        count = e.count
        cost = e.reduce(0) { $0 + $1.costUSD }
    }
}

/// Date format used across the menu and Catalog, with presets,
/// a custom pattern field, and a live preview of today's date.
private struct DateFormatField: View {
    @ObservedObject private var settings = AppSettings.shared

    private static let presets = [
        "dd MMM yyyy",       // 03 Jul 2026
        "MMM d, yyyy",       // Jul 3, 2026
        "d MMMM yyyy",       // 3 July 2026
        "EEE, dd MMM yyyy",  // Fri, 03 Jul 2026
        "yyyy-MM-dd",        // 2026-07-03
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Date format")
                Spacer()
                TextField("", text: $settings.uiDateFormat)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                    .multilineTextAlignment(.trailing)
                Menu {
                    ForEach(Self.presets, id: \.self) { preset in
                        Button("\(DateDisplay.preview(preset))  ·  \(preset)") { settings.uiDateFormat = preset }
                    }
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24)
                DefaultResetButton(isDefault: settings.uiDateFormat == AppSettings.Default.uiDateFormat) {
                    settings.uiDateFormat = AppSettings.Default.uiDateFormat
                }
            }
            Text("Preview: \(DateDisplay.preview(settings.uiDateFormat).isEmpty ? "—" : DateDisplay.preview(settings.uiDateFormat))  ·  Unicode date pattern (dd MMM yyyy). Applies to the menu and Catalog; note filenames are unaffected.")
                .font(.caption).foregroundColor(.secondary)
        }
    }
}

// MARK: - Dictation

private struct DictationPane: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsGroup("Push-to-Talk") {
                HStack {
                    Text("Hotkey")
                    Spacer()
                    Picker("", selection: $settings.pttKeyCode) {
                        ForEach(PTTKey.allCases) { key in
                            Text(key.displayName).tag(key.rawValue)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                    DefaultResetButton(isDefault: settings.pttKeyCode == AppSettings.Default.pttKeyCode) {
                        settings.pttKeyCode = AppSettings.Default.pttKeyCode
                    }
                }
                Divider()
                HStack {
                    Text("Activation")
                    Spacer()
                    Picker("", selection: $settings.pttActivation) {
                        ForEach(PTTActivation.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                    DefaultResetButton(isDefault: settings.pttActivation == .hold) {
                        settings.pttActivation = .hold
                    }
                }
                Text(settings.pttActivation.detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
                if settings.pttActivation == .tapLock {
                    DurationSlider(
                        title: "Tap vs. hold threshold",
                        value: $settings.pttTapThreshold, range: 0.15...1.0, step: 0.05, unit: "s",
                        defaultValue: AppSettings.Default.pttTapThreshold
                    )
                    Text("A press shorter than this locks hands-free; longer counts as hold-to-talk.")
                        .font(.caption).foregroundColor(.secondary)
                }
                Text("Applies immediately — no restart needed.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            SettingsGroup("Streaming") {
                Toggle("Streaming dictation", isOn: $settings.streamingDictation)
                Text("Long dictations are transcribed in chunks while you're still speaking, so the text appears almost instantly on release.")
                    .font(.caption).foregroundColor(.secondary)
                if settings.streamingDictation {
                    DurationSlider(
                        title: "Chunk length",
                        value: $settings.streamChunkSeconds, range: 5...20, step: 1, unit: "s",
                        defaultValue: AppSettings.Default.streamChunkSeconds
                    )
                }
                Text("Transcription language lives in AI & Models → Models, since it applies to meetings too.")
                    .font(.caption).foregroundColor(.secondary)
            }

            SettingsGroup("Silence") {
                Toggle("Skip silent recordings", isOn: $settings.skipSilentDictation)
                Text("Don't upload a recording (or streaming chunk) to Groq unless it actually contains speech — saves API calls and avoids Whisper inventing text from silence.")
                    .font(.caption).foregroundColor(.secondary)
                if settings.skipSilentDictation {
                    ThresholdSlider(
                        title: "Silence threshold",
                        value: $settings.dictationSilenceThreshold, range: -60...(-25),
                        defaultValue: AppSettings.Default.dictationSilenceThreshold,
                        help: "Audio quieter than this the whole time counts as silence. Lower = uploads quieter speech; higher = skips more aggressively.")
                }
            }

            SettingsGroup("Audio Import") {
                Stepper(value: $settings.audioImportMaxMB, in: 5...500, step: 5) {
                    Text("Max import size: \(settings.audioImportMaxMB) MB")
                }
                Text("“Transcribe Audio File…” (menu bar) and dropping an audio file onto the Catalog transcribe it into a meeting note, filed under the file's own date. Files are normalized to a compact 16 kHz-mono upload (Opus, falling back to FLAC) and long recordings are automatically split on silence to fit Groq's request limit, so this cap only guards the initial decode — raise it for very long recordings. Formats: wav, mp3, m4a, ogg/opus, flac, webm.")
                    .font(.caption).foregroundColor(.secondary)
            }

            SettingsGroup("Accuracy") {
                Text("Custom vocabulary").font(.caption.bold())
                MultilineField(text: $settings.vocabulary,
                               placeholder: "Kubernetes, Grafana, PostgreSQL")
                Text("Names, acronyms, jargon — comma or newline separated. Whisper biases toward these terms (e.g. Kubernetes, Grafana, PostgreSQL).")
                    .font(.caption).foregroundColor(.secondary)
                Divider()
                Text("Replacements").font(.caption.bold())
                MultilineField(text: $settings.replacements,
                               placeholder: "cuber netties => Kubernetes")
                Text("Applied after transcription, one rule per line: wrong => right (e.g. cuber netties => Kubernetes).")
                    .font(.caption).foregroundColor(.secondary)
            }

            SettingsGroup("Recall") {
                Toggle("Keep recent dictations", isOn: $settings.dictationHistoryEnabled)
                    .onChange(of: settings.dictationHistoryEnabled) { _, enabled in
                        if !enabled {
                            NotificationCenter.default.post(name: .dictationHistoryDisabled, object: nil)
                        }
                    }
                Text("Enables ⌃⌥V to re-type your most recent dictation. Kept in memory only — cleared when disabled or when the app quits. (For a browsable app/style/duration history, enable “Save each dictation to a file” below and open Dictations… from the menu bar.)")
                    .font(.caption).foregroundColor(.secondary)
                if settings.dictationHistoryEnabled {
                    HStack {
                        Text("Keep last")
                        Spacer()
                        Picker("", selection: $settings.dictationHistoryLimit) {
                            ForEach([10, 20, 50], id: \.self) { Text("\($0) dictations").tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 150)
                        DefaultResetButton(isDefault: settings.dictationHistoryLimit == AppSettings.Default.dictationHistoryLimit) {
                            settings.dictationHistoryLimit = AppSettings.Default.dictationHistoryLimit
                        }
                    }
                }
            }

            SettingsGroup("Archive") {
                Toggle("Save each dictation to a file", isOn: $settings.saveDictations)
                Text("Writes one Markdown file per dictation with metadata front-matter (app, browser host, writing style, duration, word count) plus the polished text. Browse them from the menu bar → Dictations…. Redaction, if enabled, applies before saving. Kept separate from meetings and the Catalog.")
                    .font(.caption).foregroundColor(.secondary)
                if settings.saveDictations {
                    HStack {
                        Text("Save to")
                        Spacer()
                        Text(settings.dictationsFolder.path.abbreviatingHome())
                            .font(.caption).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                        Button("Change…") {
                            if let url = chooseFolder(startingAt: settings.dictationsFolder) {
                                settings.dictationsFolder = url
                            }
                        }
                    }
                    Divider()
                    HStack {
                        Text("Organize files")
                        Spacer()
                        Picker("", selection: $settings.dictationOrganization) {
                            ForEach(NotesOrganization.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 220)
                    }
                    Text("Dated subfolders for dictation files, independent of the meeting layout. Existing files stay put; the Dictations browser finds them in any layout.")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
        }
    }
}

// MARK: - Quick Notes

private struct QuickNotesPane: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsGroup("Capture") {
                Text("Press ⌃⌥J anywhere to dictate a thought — press again to save it, Esc to discard. Notes are transcribed, lightly polished, and timestamped into one file per day (QuickNotes_2026-07-05.md).")
                    .font(.caption).foregroundColor(.secondary)
            }

            SettingsGroup("Storage") {
                HStack {
                    Text("Save to")
                    Spacer()
                    Text(settings.quickNotesFolder.path.abbreviatingHome())
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Choose…") { pickQuickNotesFolder() }
                }
                Text("Kept apart from meeting notes so meeting history and the Catalog stay meetings-only. Open the latest file via menu bar → Notes → Open Today's Quick Notes.")
                    .font(.caption).foregroundColor(.secondary)
            }

            SettingsGroup("Notifications") {
                Toggle("Notify when a quick note is saved", isOn: $settings.quickNoteNotify)
                Text("Shows the note and where it was saved — click the notification to open the file.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
    }

    private func pickQuickNotesFolder() {
        if let url = chooseFolder(startingAt: settings.quickNotesFolder) {
            settings.quickNotesFolder = url
        }
    }
}

// MARK: - Shortcuts

private struct ShortcutsPane: View {
    @ObservedObject private var settings = AppSettings.shared

    private var pttKeyName: String {
        (PTTKey(rawValue: settings.pttKeyCode) ?? .rightOption).displayName
    }

    private var pttRow: (keys: String, detail: String) {
        switch settings.pttActivation {
        case .hold:    return ("Hold \(pttKeyName)", "Push-to-talk — record while held, type on release")
        case .tapLock: return ("\(pttKeyName)", "Hold to talk, or tap to lock hands-free — tap again (or Esc) to stop")
        case .toggle:  return ("\(pttKeyName)", "Press to start recording, press again to stop")
        }
    }

    private var allShortcutsDefault: Bool {
        GlobalShortcut.allCases.allSatisfy { settings.shortcutKeyCode(for: $0) == $0.defaultKeyCode }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsGroup("Dictation") {
                ShortcutRow(keys: pttRow.keys, detail: pttRow.detail)
                ShortcutRow(keys: "Esc", detail: "Cancel an in-progress dictation (types nothing)")
                Text("The push-to-talk key and its activation mode are set in the Dictation pane.")
                    .font(.caption).foregroundColor(.secondary)
            }

            SettingsGroup("Global Shortcuts") {
                Text("All ⌃⌥-modified and system-wide, from any app. Pick a different letter for any action; the ⌃⌥ modifier is fixed so these never clash with an app's own ⌘-shortcuts.")
                    .font(.caption).foregroundColor(.secondary)
                ForEach(GlobalShortcut.allCases) { shortcut in
                    ShortcutBindingRow(shortcut: shortcut)
                }
                HStack {
                    Spacer()
                    DefaultResetButton(isDefault: allShortcutsDefault) {
                        settings.resetShortcutOverrides()
                    }
                }
            }
        }
    }
}

/// One editable ⌃⌥ global-shortcut binding: the action, a fixed ⌃⌥ badge, and a
/// letter picker. Flags a duplicate binding (first match wins at dispatch time).
private struct ShortcutBindingRow: View {
    @ObservedObject private var settings = AppSettings.shared
    let shortcut: GlobalShortcut

    var body: some View {
        let code = settings.shortcutKeyCode(for: shortcut)
        HStack(spacing: 8) {
            Text(shortcut.title)
            Spacer()
            if settings.conflictingShortcutKeys.contains(code) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .help("⌃⌥\(ShortcutKeys.label(for: code)) is used by more than one action — the first one wins. Pick another letter.")
            }
            Text("⌃⌥").font(.system(.body, design: .monospaced)).foregroundColor(.secondary)
            Picker("", selection: Binding(
                get: { settings.shortcutKeyCode(for: shortcut) },
                set: { settings.setShortcutKeyCode($0, for: shortcut) }
            )) {
                ForEach(ShortcutKeys.assignable, id: \.code) { key in
                    Text(key.label).tag(key.code)
                }
            }
            .labelsHidden()
            .frame(width: 70)
        }
    }
}

private struct ShortcutRow: View {
    let keys: String
    let detail: String

    var body: some View {
        HStack {
            Text(keys)
                .font(.system(.body, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.08)))
            Text(detail)
                .foregroundColor(.secondary)
            Spacer()
        }
    }
}

// MARK: - Meeting Mode

private struct MeetingPane: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var showAdvanced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsGroup("Call Detection") {
                Toggle("Offer to start when a call is detected", isOn: $settings.meetingAutoDetect)
                Text("When Zoom, Teams, Webex, Slack, a browser call (Google Meet), or another conferencing app starts using the microphone, GhostWriter asks whether to start Meeting Mode — and offers to stop when the call ends.")
                    .font(.caption).foregroundColor(.secondary)
            }

            SettingsGroup("Overlay") {
                HStack {
                    Text("During meetings show")
                    Spacer()
                    Picker("", selection: $settings.overlayMode) {
                        ForEach(MeetingOverlayMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 240)
                    DefaultResetButton(isDefault: settings.overlayMode == AppSettings.Default.overlayMode) {
                        settings.overlayMode = AppSettings.Default.overlayMode
                    }
                }
                Text(settings.overlayMode.help)
                    .font(.caption)
                    .foregroundColor(.secondary)
                if settings.overlayMode == .captions {
                    DurationSlider(
                        title: "Caption fade delay",
                        value: $settings.captionLingerSeconds, range: 2...15, step: 1, unit: "s",
                        defaultValue: AppSettings.Default.captionLingerSeconds
                    )
                }
            }

            SettingsGroup("Live Assistance") {
                Toggle("Live brief during meetings", isOn: $settings.liveAssistantEnabled)
                Text("Shows a small floating panel with a rolling TL;DR and the open action items while a meeting runs, refreshed as the conversation develops. Makes periodic AI calls during the meeting (a little extra cost); disabled automatically in Local-only mode.")
                    .font(.caption).foregroundColor(.secondary)
                if settings.liveAssistantEnabled {
                    HStack {
                        Text("Refresh every")
                        Spacer()
                        Picker("", selection: $settings.liveBriefInterval) {
                            ForEach([15, 25, 45, 60, 90], id: \.self) { Text("\($0)s").tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 90)
                        DefaultResetButton(isDefault: settings.liveBriefInterval == AppSettings.Default.liveBriefInterval) {
                            settings.liveBriefInterval = AppSettings.Default.liveBriefInterval
                        }
                    }
                    Text("How often the brief updates. Longer intervals mean fewer AI calls — lower cost, less frequent refreshes.")
                        .font(.caption).foregroundColor(.secondary)
                }
                Divider()
                Toggle("Show prep card on start", isOn: $settings.meetingPrepCard)
                Text("When a meeting is linked to an organisation or project, a floating panel of that entity's recent notes appears as the meeting starts. This is the default for the per-meeting switch in the start dialog.")
                    .font(.caption).foregroundColor(.secondary)
            }

            SettingsGroup("Echo Suppression") {
                Toggle("Suppress speaker echo (built-in speaker mode)", isOn: $settings.echoSuppressionEnabled)
                if settings.echoSuppressionEnabled {
                    DurationSlider(
                        title: "Mic mute window after speaker audio",
                        value: $settings.echoGateWindow, range: 0.1...1.5, step: 0.1, unit: "s",
                        defaultValue: AppSettings.Default.echoGateWindow
                    )
                }
                Text("Prevents the other side's voice — heard through your speakers — from being transcribed as you. Not needed with headphones.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            SettingsGroup("Speakers") {
                HStack {
                    Text("Your label")
                    Spacer()
                    TextField("", text: $settings.speakerLabelYou)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                        .multilineTextAlignment(.trailing)
                }
                HStack {
                    Text("Others' label")
                    Spacer()
                    TextField("", text: $settings.speakerLabelThem)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                        .multilineTextAlignment(.trailing)
                }
                Text("How you and the other participants are named in the transcript.")
                    .font(.caption).foregroundColor(.secondary)
                Divider()
                Toggle("Identify distinct speakers (experimental)", isOn: $settings.diarizationEnabled)
                Text("Fingerprints each voice (pitch and timbre) and clusters segments within a meeting, labeling remote voices Them / Them 2 / Them 3. On-device and lightweight — similar-sounding voices may still merge. Use the Notes menu ▸ Identify Speakers… to give them real names in that meeting.")
                    .font(.caption).foregroundColor(.secondary)
                if settings.diarizationEnabled {
                    HStack {
                        Text("Max distinct speakers")
                        Spacer()
                        Picker("", selection: $settings.maxSpeakers) {
                            ForEach([2, 3, 4, 5, 6], id: \.self) { Text("\($0)").tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 80)
                        DefaultResetButton(isDefault: settings.maxSpeakers == AppSettings.Default.maxSpeakers) {
                            settings.maxSpeakers = AppSettings.Default.maxSpeakers
                        }
                    }
                    HStack {
                        Text("Separation sensitivity")
                        Spacer()
                        Slider(value: $settings.speakerSensitivity, in: 0.6...1.6, step: 0.1)
                            .frame(width: 130)
                        DefaultResetButton(isDefault: settings.speakerSensitivity == AppSettings.Default.speakerSensitivity) {
                            settings.speakerSensitivity = AppSettings.Default.speakerSensitivity
                        }
                    }
                    Text("Lower separates voices more eagerly (may over-split one speaker); higher merges similar-sounding voices into one. Adjust if speakers are being split or merged incorrectly.")
                        .font(.caption).foregroundColor(.secondary)
                }
            }

            // Expert knobs, collapsed by default so the pane isn't intimidating.
            DisclosureGroup(isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 16) {
                    SettingsGroup("Voice Detection") {
                        ThresholdSlider(
                            title: "Your microphone",
                            value: $settings.meetingMicThreshold, range: -60...(-20),
                            defaultValue: AppSettings.Default.meetingMicThreshold,
                            help: "Mic audio above this level counts as your speech."
                        )
                        ThresholdSlider(
                            title: "System audio (others)",
                            value: $settings.systemAudioThreshold, range: -70...(-30),
                            defaultValue: AppSettings.Default.systemAudioThreshold,
                            help: "System audio above this level counts as the other participants speaking."
                        )
                    }

                    SettingsGroup("Segmenting") {
                        DurationSlider(
                            title: "Pause before flushing a segment",
                            value: $settings.silenceDebounce, range: 0.5...4.0, step: 0.1, unit: "s",
                            defaultValue: AppSettings.Default.silenceDebounce
                        )
                        DurationSlider(
                            title: "Maximum segment length",
                            value: $settings.maxSegmentSeconds, range: 10...25, step: 1, unit: "s",
                            defaultValue: AppSettings.Default.maxSegmentSeconds
                        )
                    }

                    SettingsGroup("Failed-Segment Retry") {
                        HStack {
                            Text("Retry attempts")
                            Spacer()
                            Picker("", selection: $settings.retryMaxAttempts) {
                                ForEach([1, 2, 3, 5], id: \.self) { Text("\($0)").tag($0) }
                            }
                            .labelsHidden()
                            .frame(width: 80)
                            DefaultResetButton(isDefault: settings.retryMaxAttempts == AppSettings.Default.retryMaxAttempts) {
                                settings.retryMaxAttempts = AppSettings.Default.retryMaxAttempts
                            }
                        }
                        DurationSlider(
                            title: "Retry interval",
                            value: $settings.retryIntervalSeconds, range: 5...60, step: 5, unit: "s",
                            defaultValue: AppSettings.Default.retryIntervalSeconds
                        )
                        Text("Segments that fail to transcribe (network blips) are retried; exhausted ones become visible markers in the notes.")
                            .font(.caption).foregroundColor(.secondary)
                    }

                    SettingsGroup("Detection & Timing") {
                        DurationSlider(
                            title: "Auto-detect poll interval",
                            value: $settings.meetingDetectInterval, range: 1...10, step: 0.5, unit: "s",
                            defaultValue: AppSettings.Default.meetingDetectInterval
                        )
                        HStack {
                            Text("Meeting-end sensitivity")
                            Spacer()
                            Stepper("\(settings.meetingEndQuietPolls) quiet poll\(settings.meetingEndQuietPolls == 1 ? "" : "s")",
                                    value: $settings.meetingEndQuietPolls, in: 1...5)
                                .frame(width: 170)
                            DefaultResetButton(isDefault: settings.meetingEndQuietPolls == AppSettings.Default.meetingEndQuietPolls) {
                                settings.meetingEndQuietPolls = AppSettings.Default.meetingEndQuietPolls
                            }
                        }
                        HStack {
                            Text("Transcription request timeout")
                            Spacer()
                            Picker("", selection: $settings.transcriptionTimeout) {
                                ForEach([15, 30, 45, 60, 90, 120], id: \.self) { Text("\($0)s").tag($0) }
                            }
                            .labelsHidden().frame(width: 80)
                            DefaultResetButton(isDefault: settings.transcriptionTimeout == AppSettings.Default.transcriptionTimeout) {
                                settings.transcriptionTimeout = AppSettings.Default.transcriptionTimeout
                            }
                        }
                        HStack {
                            Text("Audio-import request timeout")
                            Spacer()
                            Picker("", selection: $settings.importTranscriptionTimeout) {
                                ForEach([30, 60, 120, 180, 300], id: \.self) { Text("\($0)s").tag($0) }
                            }
                            .labelsHidden().frame(width: 80)
                            DefaultResetButton(isDefault: settings.importTranscriptionTimeout == AppSettings.Default.importTranscriptionTimeout) {
                                settings.importTranscriptionTimeout = AppSettings.Default.importTranscriptionTimeout
                            }
                        }
                        HStack {
                            Text("Live-brief refresh threshold")
                            Spacer()
                            Stepper("\(settings.liveBriefMinGrowth) chars", value: $settings.liveBriefMinGrowth,
                                    in: 100...2000, step: 50)
                                .frame(width: 170)
                            DefaultResetButton(isDefault: settings.liveBriefMinGrowth == AppSettings.Default.liveBriefMinGrowth) {
                                settings.liveBriefMinGrowth = AppSettings.Default.liveBriefMinGrowth
                            }
                        }
                        HStack {
                            Text("Summary context budget")
                            Spacer()
                            Stepper("\(settings.summaryContextChars / 1000)k chars", value: $settings.summaryContextChars,
                                    in: 8000...60000, step: 4000)
                                .frame(width: 170)
                            DefaultResetButton(isDefault: settings.summaryContextChars == AppSettings.Default.summaryContextChars) {
                                settings.summaryContextChars = AppSettings.Default.summaryContextChars
                            }
                        }
                        Text("How often GhostWriter polls for a call, how many quiet polls end one, request timeouts for live vs. imported audio, how much new speech triggers a fresh live brief, and how much transcript is fed into AI summaries (higher = more complete, higher token cost).")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
                .padding(.top, 8)
            } label: {
                Label("Advanced", systemImage: "slider.horizontal.3")
                    .font(.headline)
            }
        }
    }

}

// MARK: - Helpers

extension Notification.Name {
    static let showAPIKeyWindow    = Notification.Name("ShowAPIKeyWindow")
    static let settingsDidReset    = Notification.Name("SettingsDidReset")
    static let resetAllPermissions = Notification.Name("ResetAllPermissions")
    static let dictationHistoryDisabled = Notification.Name("DictationHistoryDisabled")
    static let renameSpeakersForFile = Notification.Name("RenameSpeakersForFile")
    static let openDigest = Notification.Name("OpenDigest")
    static let openNoteFile = Notification.Name("OpenNoteFile")
    /// Reveal a note *inside* the Catalog (select + scroll to it), as opposed to
    /// `.openNoteFile` which opens it in the standalone viewer. `object` is the
    /// `CatalogNote.id` (String). The app observes it, fronts the Catalog window,
    /// then re-broadcasts `.selectCatalogNote` once the window is live.
    static let revealNoteInCatalog = Notification.Name("RevealNoteInCatalog")
    /// App → CatalogView hand-off for `.revealNoteInCatalog`. Posted only after
    /// the Catalog window exists so the view's observer can't miss it. `object`
    /// is the `CatalogNote.id` (String).
    static let selectCatalogNote = Notification.Name("SelectCatalogNote")
    /// App → CatalogView: switch to the Notes section (the single full browser),
    /// clearing any active search/filter. Posted after the window is live.
    static let showCatalogNotes = Notification.Name("ShowCatalogNotes")
}

// MARK: - About

private struct AboutPane: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
    private var build: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsGroup("GhostWriter") {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                        .resizable()
                        .frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("GhostWriter")
                            .font(.title3.weight(.semibold))
                        Text("Version \(version)\(build.map { " (\($0))" } ?? "")")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                Text("A menu-bar dictation and meeting-transcription assistant. Hold a key to speak polished text into any app; Meeting Mode captures both sides of a call into speaker-labeled Markdown notes with AI summaries.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            SettingsGroup("Powered By") {
                Text("Transcription and polishing by Groq (Whisper + Llama). Offline fallback and diarization run fully on-device. Your API key stays in the macOS Keychain; audio never touches disk.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Text("© \(String(Calendar.current.component(.year, from: Date()))) GhostWriter. Built natively for Apple Silicon.")
                .font(.caption2)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 4)
        }
    }
}

// Shared with NotificationManager (quick-note "saved to" path display).
extension String {
    func abbreviatingHome() -> String {
        (self as NSString).abbreviatingWithTildeInPath
    }
}

/// One folder chooser for every "Save to → Choose…" row.
func chooseFolder(startingAt current: URL) -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.directoryURL = current
    panel.prompt = "Choose"
    return panel.runModal() == .OK ? panel.url : nil
}
