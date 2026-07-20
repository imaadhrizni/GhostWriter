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
        .init(label: "Date format", section: .general, keywords: ["timestamp", "filename", "default", "reset"]),
        .init(label: "PDF paper size (Letter / A4)", section: .general, keywords: ["pdf", "export", "paper", "a4", "letter", "page size", "print", "report", "poc"]),
        .init(label: "Menu-bar icon", section: .general, keywords: ["status item", "tray", "default", "reset"]),
        // AI & Models
        .init(label: "Groq API key", section: .ai, keywords: ["token", "account", "authentication", "credential", "change", "clear", "remove"]),
        .init(label: "Transcription model", section: .ai, keywords: ["whisper", "speech to text", "stt", "default", "reset"]),
        .init(label: "Polishing model", section: .ai, keywords: ["llama", "qwen", "summaries", "llm", "chat", "default", "reset"]),
        .init(label: "Lightweight-tasks model", section: .ai, keywords: ["fast", "cheap", "background", "live brief", "default", "reset"]),
        .init(label: "Transcription language", section: .ai, keywords: ["iso", "locale", "tamil", "sinhala", "german", "default", "reset"]),
        .init(label: "Offline fallback", section: .ai, keywords: ["on-device", "apple", "no network", "private"]),
        .init(label: "Prefer on-device AI", section: .ai, keywords: ["apple intelligence", "private", "local llm"]),
        // Dictation
        .init(label: "Dictation hotkey", section: .dictation, keywords: ["shortcut", "push to talk", "trigger", "default", "reset"]),
        .init(label: "Activation (hold / tap-to-lock / toggle)", section: .dictation, keywords: ["hands-free", "hands free", "toggle", "tap to lock", "latch", "hold", "long dictation", "push to talk", "ptt"]),
        .init(label: "Skip silent recordings", section: .dictation, keywords: ["silence", "silent", "vad", "voice activity", "threshold", "dbfs", "noise gate", "skip", "save api", "hallucination"]),
        .init(label: "Audio import (max size)", section: .dictation, keywords: ["import", "transcribe file", "audio file", "wav", "mp3", "ogg", "opus", "m4a", "drag drop", "voice note", "chat"]),
        .init(label: "Voice commands", section: .styles, keywords: ["dictation commands", "new paragraph", "scratch that", "phrase", "effect", "rules"]),
        .init(label: "Per-app style overrides", section: .styles, keywords: ["app", "bundle id", "override", "force style", "slack", "vscode", "per app"]),
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
                    TextField("en", text: $settings.transcriptionLanguage)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                    DefaultResetButton(isDefault: settings.transcriptionLanguage == AppSettings.Default.transcriptionLanguage) {
                        settings.transcriptionLanguage = AppSettings.Default.transcriptionLanguage
                    }
                }
                Text("ISO 639-1 code hint for Whisper (en, de, ta, si, …) — applies to both dictation and meetings. Leave as en unless you speak another language.")
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

/// Editable model name with a preset menu and reset-to-default.
private struct ModelField: View {
    let title: String
    let presets: [String]
    let defaultValue: String
    @Binding var value: String

    var body: some View {
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
                Stepper(value: $settings.audioImportMaxMB, in: 5...200, step: 5) {
                    Text("Max import size: \(settings.audioImportMaxMB) MB")
                }
                Text("“Transcribe Audio File…” (menu bar) and dropping an audio file onto the Catalog transcribe it into a meeting note, filed under the file's own date. Larger files are rejected before upload. Formats: wav, mp3, m4a, ogg/opus, flac, webm.")
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

// MARK: - Writing Styles (dictation output shaping)

private struct WritingStylesPane: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsGroup("Voice Commands") {
                Toggle("Voice commands", isOn: $settings.voiceCommandsEnabled)
                Text("Say \"new paragraph\", \"comma\", \"scratch that\", or \"all caps … end caps\" while dictating.")
                    .font(.caption).foregroundColor(.secondary)
                if settings.voiceCommandsEnabled {
                    Text("Each rule is a spoken phrase and the effect it triggers. Edit freely; the polishing model follows them.")
                        .font(.caption).foregroundColor(.secondary)
                    VoiceCommandEditor()
                }
            }

            SettingsGroup("Writing Styles") {
                DictationStyleManager()
            }

            SettingsGroup("Per-App Style Overrides") {
                Text("Force a built-in style for a specific app. Use “Add current app” to grab the frontmost app's ID. Custom styles apply via the default above.")
                    .font(.caption).foregroundColor(.secondary)
                AppProfileEditor()
            }

            SettingsGroup("Browser Tab Styles") {
                Toggle("Detect the active browser tab", isOn: $settings.browserTabDetection)
                Text("Reads the frontmost browser tab's address (Safari and Chromium browsers; not Firefox) so a website can get its own style — e.g. Gmail uses the Email style instead of the generic Browser one. Needs the Automation permission (prompted once). Off: every browser uses the Browser style.")
                    .font(.caption).foregroundColor(.secondary)
                if settings.browserTabDetection {
                    Text("Give a website its own style. First matching host wins; unmatched tabs use the Browser style.")
                        .font(.caption).foregroundColor(.secondary)
                    DomainStyleEditor()
                }
            }
        }
    }
}

/// Row-based editor for browser-tab style rules. The host stays free text, but
/// the style is a Picker over the closed set of built-in + custom styles, so it
/// can't be mistyped. Backed by the same newline `host: style` string, with a
/// collapsible bulk-edit box; a bulk edit re-hydrates the rows and vice-versa.
private struct DomainStyleEditor: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var rules: [Rule] = []
    @State private var showBulk = false

    private struct Rule: Identifiable, Equatable {
        let id = UUID()
        var host: String
        var style: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if rules.isEmpty {
                Text("No site rules yet.").font(.caption).foregroundColor(.secondary)
            } else {
                ForEach($rules) { $rule in
                    HStack(spacing: 8) {
                        TextField("mail.google.com", text: $rule.host)
                            .textFieldStyle(.roundedBorder)
                        Image(systemName: "arrow.right").font(.caption2).foregroundColor(.secondary)
                        Picker("", selection: $rule.style) {
                            ForEach(styleOptions(including: rule.style), id: \.key) { opt in
                                Text(opt.label).tag(opt.key)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 130)
                        Button { rules.removeAll { $0.id == rule.id } } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .buttonStyle(.plain).foregroundColor(.secondary).help("Remove")
                    }
                }
            }

            HStack {
                Button {
                    rules.append(Rule(host: "", style: settings.dictationStyleKeys.first?.key ?? "email"))
                } label: {
                    Label("Add rule", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                Spacer()
                DefaultResetButton(isDefault: settings.domainStyleRules == AppSettings.Default.domainStyleRules) {
                    settings.domainStyleRules = AppSettings.Default.domainStyleRules
                    hydrate()
                }
            }

            DisclosureGroup(isExpanded: $showBulk) {
                MultilineField(text: $settings.domainStyleRules,
                               placeholder: "mail.google.com: email\ngithub.com: code",
                               minHeight: 70,
                               font: .system(.caption, design: .monospaced))
                Text("One rule per line, host: style. Edits here stay in sync with the rows above.")
                    .font(.caption2).foregroundColor(.secondary)
            } label: {
                Text("Paste or edit as a list").font(.caption)
            }
        }
        .onAppear(perform: hydrate)
        // Rows → storage. Guard against echoing our own write back into hydrate.
        .onChange(of: rules) { _, new in
            let serialized = serialize(new)
            if serialized != settings.domainStyleRules { settings.domainStyleRules = serialized }
        }
        // Storage → rows, for external edits (bulk box, reset) only.
        .onChange(of: settings.domainStyleRules) { _, new in
            if new != serialize(rules) { hydrate() }
        }
    }

    /// The style menu, guaranteeing the row's current key is present even if it
    /// points at a since-deleted custom style (so the Picker still shows it).
    private func styleOptions(including current: String) -> [(key: String, label: String)] {
        var opts = settings.dictationStyleKeys
        if !current.isEmpty && !opts.contains(where: { $0.key == current }) {
            opts.append((current, "\(current) (missing)"))
        }
        return opts
    }

    private func hydrate() {
        rules = settings.domainStyleList.map { Rule(host: $0.host, style: $0.style) }
    }
    private func serialize(_ list: [Rule]) -> String {
        list.map { ($0.host.trimmingCharacters(in: .whitespaces), $0.style) }
            .filter { !$0.0.isEmpty }
            .map { "\($0.0): \($0.1)" }
            .joined(separator: "\n")
    }
}

/// Row-based editor for per-app style overrides. Same shape as the browser-tab
/// editor — a bundle-ID field + a style Picker (built-ins only) — plus an
/// "Add app…" menu of running apps so you don't have to hunt for bundle IDs.
/// Backed by the same newline `bundle.id: style` string, kept in sync with a
/// collapsible bulk-edit box.
private struct AppProfileEditor: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var rules: [Rule] = []
    @State private var showBulk = false

    private struct Rule: Identifiable, Equatable {
        let id = UUID()
        var bundleID: String
        var style: String
    }

    private var defaultStyle: String { settings.builtInStyleKeys.first?.key ?? "general" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if rules.isEmpty {
                Text("No app overrides yet.").font(.caption).foregroundColor(.secondary)
            } else {
                ForEach($rules) { $rule in
                    HStack(spacing: 8) {
                        TextField("com.tinyspeck.slackmacgap", text: $rule.bundleID)
                            .textFieldStyle(.roundedBorder)
                        Image(systemName: "arrow.right").font(.caption2).foregroundColor(.secondary)
                        Picker("", selection: $rule.style) {
                            ForEach(styleOptions(including: rule.style), id: \.key) { opt in
                                Text(opt.label).tag(opt.key)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 130)
                        Button { rules.removeAll { $0.id == rule.id } } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .buttonStyle(.plain).foregroundColor(.secondary).help("Remove")
                    }
                }
            }

            HStack {
                Menu {
                    ForEach(runningApps(), id: \.bundleID) { app in
                        Button(app.name) { add(bundleID: app.bundleID) }
                    }
                    Divider()
                    Button("Blank row") { add(bundleID: "") }
                } label: {
                    Label("Add app…", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Spacer()
                DefaultResetButton(isDefault: settings.appProfiles.isEmpty) {
                    settings.appProfiles = ""
                    hydrate()
                }
            }

            DisclosureGroup(isExpanded: $showBulk) {
                MultilineField(text: $settings.appProfiles,
                               placeholder: "com.tinyspeck.slackmacgap: messaging\ncom.microsoft.VSCode: code",
                               minHeight: 70,
                               font: .system(.caption, design: .monospaced))
                Text("One override per line, bundle.id: style. Edits here stay in sync with the rows above.")
                    .font(.caption2).foregroundColor(.secondary)
            } label: {
                Text("Paste or edit as a list").font(.caption)
            }
        }
        .onAppear(perform: hydrate)
        .onChange(of: rules) { _, new in
            let serialized = serialize(new)
            if serialized != settings.appProfiles { settings.appProfiles = serialized }
        }
        .onChange(of: settings.appProfiles) { _, new in
            if new != serialize(rules) { hydrate() }
        }
    }

    private func add(bundleID: String) {
        // Don't add a duplicate; just focus stays where it is if already present.
        guard bundleID.isEmpty || !rules.contains(where: { $0.bundleID == bundleID }) else { return }
        rules.append(Rule(bundleID: bundleID, style: defaultStyle))
    }

    /// Currently-running regular apps (excluding GhostWriter itself), by name.
    private func runningApps() -> [(name: String, bundleID: String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> (String, String)? in
                guard let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier,
                      let name = app.localizedName else { return nil }
                return (name, id)
            }
            .sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
            .map { (name: $0.0, bundleID: $0.1) }
    }

    private func styleOptions(including current: String) -> [(key: String, label: String)] {
        var opts = settings.builtInStyleKeys
        if !current.isEmpty && !opts.contains(where: { $0.key == current }) {
            opts.append((current, "\(current) (missing)"))
        }
        return opts
    }

    private func hydrate() {
        rules = settings.appProfileList.map { Rule(bundleID: $0.bundleID, style: $0.style) }
    }
    private func serialize(_ list: [Rule]) -> String {
        list.map { ($0.bundleID.trimmingCharacters(in: .whitespaces), $0.style) }
            .filter { !$0.0.isEmpty }
            .map { "\($0.0): \($0.1)" }
            .joined(separator: "\n")
    }
}

/// Row-based editor for voice commands. Each rule is a spoken phrase and the
/// effect it triggers, shown as a two-column row. There's no structured model
/// behind this — the rows serialize back to the same free-form
/// "phrase → effect" lines the polishing model reads, so the LLM keeps its
/// latitude to interpret fuzzy phrasing. Collapsible bulk-edit box included.
private struct VoiceCommandEditor: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var rules: [Rule] = []
    @State private var showBulk = false

    private struct Rule: Identifiable, Equatable {
        let id = UUID()
        var phrase: String
        var effect: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if rules.isEmpty {
                Text("No voice commands yet.").font(.caption).foregroundColor(.secondary)
            } else {
                ForEach($rules) { $rule in
                    HStack(spacing: 8) {
                        TextField("spoken phrase", text: $rule.phrase)
                            .textFieldStyle(.roundedBorder)
                        Image(systemName: "arrow.right").font(.caption2).foregroundColor(.secondary)
                        TextField("effect", text: $rule.effect)
                            .textFieldStyle(.roundedBorder)
                        Button { rules.removeAll { $0.id == rule.id } } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .buttonStyle(.plain).foregroundColor(.secondary).help("Remove")
                    }
                }
            }

            HStack {
                Button { rules.append(Rule(phrase: "", effect: "")) } label: {
                    Label("Add command", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                Spacer()
                DefaultResetButton(isDefault: settings.voiceCommandRules == AppSettings.Default.voiceCommandRules) {
                    settings.voiceCommandRules = AppSettings.Default.voiceCommandRules
                    hydrate()
                }
            }

            DisclosureGroup(isExpanded: $showBulk) {
                MultilineField(text: $settings.voiceCommandRules,
                               placeholder: "new paragraph → line break\nscratch that → delete last sentence",
                               minHeight: 70,
                               font: .system(.caption, design: .monospaced))
                Text("One rule per line, phrase → effect. Edits here stay in sync with the rows above.")
                    .font(.caption2).foregroundColor(.secondary)
            } label: {
                Text("Paste or edit as a list").font(.caption)
            }
        }
        .onAppear(perform: hydrate)
        .onChange(of: rules) { _, new in
            let serialized = serialize(new)
            if serialized != settings.voiceCommandRules { settings.voiceCommandRules = serialized }
        }
        .onChange(of: settings.voiceCommandRules) { _, new in
            if new != serialize(rules) { hydrate() }
        }
    }

    private func hydrate() {
        rules = settings.voiceCommandRules
            .split(whereSeparator: \.isNewline)
            .compactMap { line in
                let parts = line.components(separatedBy: "→")
                let phrase = parts.first?.trimmingCharacters(in: .whitespaces) ?? ""
                let effect = parts.count > 1 ? parts[1...].joined(separator: "→").trimmingCharacters(in: .whitespaces) : ""
                guard !phrase.isEmpty else { return nil }
                return Rule(phrase: phrase, effect: effect)
            }
    }
    private func serialize(_ list: [Rule]) -> String {
        list.map { ($0.phrase.trimmingCharacters(in: .whitespaces), $0.effect.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.0.isEmpty }
            .map { $0.1.isEmpty ? $0.0 : "\($0.0) → \($0.1)" }
            .joined(separator: "\n")
    }
}

/// Manages dictation writing styles: pick one to edit, set the global default
/// for unrecognized apps, add/rename/delete custom styles, and edit the
/// instruction text of whichever is selected. Built-in styles (one per app
/// category) are editable and resettable; custom styles are fully yours.
private struct DictationStyleManager: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var selectedID: String = AppSettings.shared.defaultDictationStyleID
    @State private var confirmingDelete = false

    private var selected: DictationStyle {
        settings.dictationStyle(withID: selectedID) ?? .builtIn(.general)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Style")
                Spacer()
                Picker("", selection: $selectedID) {
                    ForEach(settings.allDictationStyles) { style in
                        Text(style.displayName).tag(style.id)
                    }
                }
                .labelsHidden()
                .frame(width: 160)
                Button {
                    selectedID = settings.addUserDictationStyle(name: "New Style")
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add a new style")
                if !selected.isBuiltIn {
                    Button(role: .destructive) {
                        confirmingDelete = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .help("Delete this style")
                }
            }
            Text("Recognized apps (mail, chat, code editors, browsers, notes) auto-pick their matching style. Edit any style's instructions below, or add your own.")
                .font(.caption).foregroundColor(.secondary)

            if settings.defaultDictationStyleID == selectedID {
                Label("Default for unrecognized apps", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundColor(.secondary)
            } else {
                Button("Set as default for unrecognized apps") {
                    settings.defaultDictationStyleID = selectedID
                }
                .font(.caption)
            }

            if !selected.isBuiltIn {
                DictationStyleNameField(id: selected.id, name: selected.displayName)
            }

            DictationStyleEditor(style: selected)
        }
        .alert("Delete “\(selected.displayName)”?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) {
                settings.deleteUserDictationStyle(id: selected.id)
                selectedID = settings.defaultDictationStyleID
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This style will be removed. Any default pointing to it falls back to General.")
        }
    }
}

/// Rename field for a user dictation style, committing on change.
private struct DictationStyleNameField: View {
    let id: String
    @ObservedObject private var settings = AppSettings.shared
    @State private var name: String

    init(id: String, name: String) {
        self.id = id
        _name = State(initialValue: name)
    }

    var body: some View {
        HStack {
            Text("Name")
            TextField("Style name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onChange(of: name) { _, newValue in
                    settings.updateUserDictationStyle(id: id, name: newValue)
                }
        }
        .onChange(of: id) { _, _ in name = settings.dictationStyle(withID: id)?.displayName ?? "" }
    }
}

/// Editor for the instruction text of the selected dictation style. Built-in
/// overrides can be reset to defaults; user styles just save their text.
private struct DictationStyleEditor: View {
    let style: DictationStyle
    @ObservedObject private var settings = AppSettings.shared
    @State private var text: String = ""

    private var isBuiltInDefault: Bool {
        if case .builtIn(let c) = style {
            return settings.dictationStyleOverride(for: c) == nil
        }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Instructions — how the model should clean up and format this text.")
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
                if case .builtIn(let c) = style {
                    DefaultResetButton(isDefault: isBuiltInDefault) {
                        settings.setDictationStyleOverride("", for: c)
                        text = c.defaultInstruction
                    }
                }
            }
            MultilineField(text: $text,
                           placeholder: "Describe how the model should clean up and format this text…",
                           minHeight: 90,
                           font: .system(.caption, design: .monospaced))
                .onChange(of: text) { _, newValue in save(newValue) }
        }
        .onAppear { text = style.instruction }
        .onChange(of: style.id) { _, _ in text = style.instruction }
    }

    private func save(_ newValue: String) {
        switch style {
        case .builtIn(let c): settings.setDictationStyleOverride(newValue, for: c)
        case .user(let s):    settings.updateUserDictationStyle(id: s.id, instruction: newValue)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsGroup("Dictation") {
                ShortcutRow(keys: pttRow.keys, detail: pttRow.detail)
                ShortcutRow(keys: "Esc", detail: "Cancel an in-progress dictation (types nothing)")
                ShortcutRow(keys: "⌃⌥V", detail: "Type the most recent dictation again")
                ShortcutRow(keys: "⌃⌥J", detail: "Quick note — dictate into today's notes file (press again to save, Esc to cancel)")
            }

            SettingsGroup("Meeting Mode") {
                ShortcutRow(keys: "⌃⌥M", detail: "Start / stop Meeting Mode")
                ShortcutRow(keys: "⌃⌥P", detail: "Pause / resume meeting transcription")
                ShortcutRow(keys: "⌃⌥B", detail: "Bookmark the current moment in a running meeting")
                ShortcutRow(keys: "⌃⌥N", detail: "Open meeting notes (live file, or the notes folder)")
            }

            Text("All shortcuts work system-wide, from any app. The push-to-talk key can be changed in the Dictation pane.")
                .font(.caption)
                .foregroundColor(.secondary)
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
                Toggle("Label distinct speakers (experimental)", isOn: $settings.diarizationEnabled)
                Text("Fingerprints each voice (pitch and timbre) and clusters segments, labeling remote voices Them / Them 2 / Them 3. On-device and lightweight — similar-sounding voices may still merge. Use the Notes menu ▸ Rename Speakers… to give them real names per meeting.")
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

// MARK: - Meeting Notes

private struct MeetingNotesPane: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsGroup("Files") {
                HStack {
                    Text("Save to")
                    Spacer()
                    Text(settings.notesFolder.path.abbreviatingHome())
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Choose…") { pickNotesFolder() }
                }
                Divider()
                HStack {
                    Text("Organize files")
                    Spacer()
                    Picker("", selection: $settings.notesOrganization) {
                        ForEach(NotesOrganization.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }
                Text("New meetings are saved into dated subfolders so the notes folder stays tidy. Existing files stay where they are — history, search, and stats find them either way.")
                    .font(.caption).foregroundColor(.secondary)
                Divider()
                Toggle("Obsidian/Notion front-matter", isOn: $settings.frontMatterEnabled)
                Text("Prepends YAML metadata (title, date, tags) to each notes file.")
                    .font(.caption).foregroundColor(.secondary)
            }

            SettingsGroup("Summary Content") {
                Toggle("Append AI summary when a meeting ends", isOn: $settings.summariesEnabled)
                Text("Adds the template's sections to the notes file.")
                    .font(.caption).foregroundColor(.secondary)
                Divider()
                Toggle("Append action items", isOn: $settings.actionItemsEnabled)
                Text("Adds an Action Items checklist (with owners when identifiable). Shown per note in the Catalog, with export to Reminders.")
                    .font(.caption).foregroundColor(.secondary)
            }

            SettingsGroup("AI Extraction") {
                Text("Extra passes that enrich the summary. Each needs network access and is skipped in Local-only mode.")
                    .font(.caption).foregroundColor(.secondary)
                Divider()
                Toggle("Extract decisions & risks", isOn: $settings.structuredExtraction)
                Text("Adds Decisions and Risks & Blockers sections to the summary. (Open Questions has its own toggle below.)")
                    .font(.caption).foregroundColor(.secondary)
                Divider()
                Toggle("Extract key fields per meeting type", isOn: $settings.extractKeyFields)
                Text("Pulls the fields that matter for the chosen template — a customer call's deal stage, budget, timeline, and next step; an interview's recommendation; a 1:1's sentiment — into a Key Details section and machine-readable front-matter. Categorical fields (deal stage, recommendation, sentiment) are mirrored into tags so you can filter by them in the Catalog.")
                    .font(.caption).foregroundColor(.secondary)
                Divider()
                Toggle("Extract unanswered questions", isOn: $settings.extractUnanswered)
                Text("Fills the note's Open Questions section — questions raised in the meeting that never got a clear answer, i.e. your follow-up list — as tickable checkboxes you can mark answered in the Catalog. Merges with the summary's own Open Questions if that's enabled. One extra AI call.")
                    .font(.caption).foregroundColor(.secondary)
                Divider()
                Toggle("Add topic chapters", isOn: $settings.topicChapters)
                Text("Appends a timestamped jump-list segmenting the meeting into topics. One extra AI call per meeting.")
                    .font(.caption).foregroundColor(.secondary)
            }

            SettingsGroup("Keyword Radar") {
                KeywordRadarEditor()
            }

            SettingsGroup("Metadata & Notifications") {
                Toggle("Auto-tag topics & entities into front-matter", isOn: $settings.autoTagging)
                Text("After summarizing, extract topic tags plus the people, customer, and project a meeting is about — mirrored into tags and written as structured attendees/customer/project fields (great for Obsidian/Notion graphs and Dataview). Names are skipped when redaction is on. Requires front-matter enabled and network access.")
                    .font(.caption).foregroundColor(.secondary)
                Divider()
                Toggle("Notify when notes are saved", isOn: $settings.notifyOnMeetingEnd)
            }

            SettingsGroup("Catalog Search") {
                HStack {
                    Text("Search depth (recent meetings)")
                    Spacer()
                    Picker("", selection: $settings.searchDepth) {
                        ForEach([100, 200, 500, 1000], id: \.self) { Text("\($0)").tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 100)
                    DefaultResetButton(isDefault: settings.searchDepth == AppSettings.Default.searchDepth) {
                        settings.searchDepth = AppSettings.Default.searchDepth
                    }
                }
                Text("How many recent meetings the Catalog's Meaning search and Ask scan. Higher reaches further back but is slower on large archives.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
    }

    private func pickNotesFolder() {
        if let url = chooseFolder(startingAt: settings.notesFolder) {
            let oldFolder = settings.notesFolder
            settings.notesFolder = url
            CatalogStore.shared.notesFolderDidChange(from: oldFolder)
        }
    }
}

/// Keyword Radar watchlist editor — a friendly chip UI: type a term and press
/// Return (or Add) to append it, tap a chip's ✕ to remove it, with a bulk
/// paste/edit box tucked into a disclosure for power users. Backed by the same
/// newline-separated `watchlistKeywords` string, so scanning is unaffected.
private struct KeywordRadarEditor: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var newTerm = ""
    @State private var showBulk = false
    @FocusState private var addFocused: Bool

    private var terms: [String] { settings.watchlist() }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Flag terms — competitors, product names, risk phrases. Every finished meeting is scanned locally (works offline); matches surface in a Mentions section and, with front-matter on, as filterable tags. See the cross-meeting rollup in Catalog → Tools → Keyword Radar.")
                .font(.caption).foregroundColor(.secondary)

            // Add a term — type and press Return, or hit Add.
            HStack {
                TextField("Add a term…", text: $newTerm)
                    .textFieldStyle(.roundedBorder)
                    .focused($addFocused)
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            // Current terms as removable chips.
            if terms.isEmpty {
                Text("No terms yet — nothing is scanned.")
                    .font(.caption).foregroundColor(.secondary)
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(terms, id: \.self) { term in
                        KeywordChip(term: term) { settings.removeWatchlistTerm(term) }
                    }
                }
                HStack {
                    Text("\(terms.count) term\(terms.count == 1 ? "" : "s") tracked")
                        .font(.caption).foregroundColor(.secondary)
                    Spacer()
                    Button("Clear All", role: .destructive) { settings.watchlistKeywords = "" }
                        .font(.caption)
                }
            }

            // Power-user bulk edit — same underlying list.
            DisclosureGroup(isExpanded: $showBulk) {
                MultilineField(text: $settings.watchlistKeywords,
                               placeholder: "Acme Corp\nlatency\nrenewal",
                               minHeight: 80,
                               font: .system(.caption, design: .monospaced))
                Text("One term per line (commas also work). Edits here stay in sync with the chips above.")
                    .font(.caption).foregroundColor(.secondary)
            } label: {
                Text("Paste or edit as a list").font(.caption)
            }
        }
    }

    private func add() {
        settings.addWatchlistTerms(newTerm)
        newTerm = ""
        addFocused = true
    }
}

/// A single removable watchlist term pill.
private struct KeywordChip: View {
    let term: String
    let onRemove: () -> Void
    var body: some View {
        HStack(spacing: 4) {
            Text(term).font(.callout).lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill").font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .help("Remove")
        }
        .pillBackground(.accentColor, opacity: 0.12, hPad: 8, vPad: 3, stroke: 0.25)
    }
}

/// Draft Templates — edit the drafting guidance behind each output document
/// type (the Draft… menu in the note viewer). Each type has an editable
/// instruction with a per-item reset to the built-in default.
/// Meeting templates — split out of Notes & Summaries (which had grown to eight
/// groups). Owns the meeting-type template editor and the shared template
/// import/export, sitting beside Draft Templates under Meetings.
private struct MeetingTemplatesPane: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsGroup("Meeting Templates") {
                Text("Each meeting type shapes what the summary extracts and how a follow-up is drafted. Edit the built-ins or add your own.")
                    .font(.caption).foregroundColor(.secondary)
                TemplateManager()
            }
            TemplateTransferSection()
        }
    }
}

/// Pick-and-reorder editor for the Follow-Up Packet's sections. The packet is
/// one composed document, so order is meaningful — sections render top-to-bottom
/// in this list. Any draft-document type can be added; the curated three
/// (email / POC plan / action items) keep their special grounding at generation
/// time regardless of position.
private struct PacketSectionsEditor: View {
    @ObservedObject private var settings = AppSettings.shared

    private var ids: [String] { settings.packetSectionIDs }

    /// Draft docs not already in the packet, for the "Add section" menu.
    private var availableGroups: [(title: String, docs: [DraftDoc])] {
        settings.groupedDraftDocs.compactMap { group in
            let docs = group.docs.filter { !ids.contains($0.id) }
            return docs.isEmpty ? nil : (group.title, docs)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("The note viewer's one-click packet assembles these sections, in this order, into a single document grounded in the meeting.")
                .font(.caption).foregroundColor(.secondary)

            if ids.isEmpty {
                Text("No sections — the packet would be empty. Add at least one below.")
                    .font(.caption).foregroundColor(.orange)
            } else {
                ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                    row(index: index, id: id)
                }
            }

            HStack(spacing: 8) {
                Menu {
                    ForEach(availableGroups, id: \.title) { group in
                        Section(group.title) {
                            ForEach(group.docs) { doc in
                                Button(doc.displayName) { settings.packetSectionIDs = ids + [doc.id] }
                            }
                        }
                    }
                } label: {
                    Label("Add section", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(availableGroups.isEmpty)

                Spacer()

                Text("\(ids.count) section\(ids.count == 1 ? "" : "s") · each is a separate AI call")
                    .font(.caption2).foregroundColor(.secondary)

                DefaultResetButton(isDefault: ids == AppSettings.defaultPacketSections) {
                    settings.packetSectionIDs = AppSettings.defaultPacketSections
                }
            }
        }
    }

    @ViewBuilder private func row(index: Int, id: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon(for: id)).foregroundColor(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(label(for: id))
                if let note = groundingNote(for: id) {
                    Text(note).font(.caption2).foregroundColor(.secondary)
                }
            }
            Spacer()
            Button { move(index, by: -1) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.plain).foregroundColor(.secondary)
                .disabled(index == 0)
            Button { move(index, by: 1) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.plain).foregroundColor(.secondary)
                .disabled(index == ids.count - 1)
            Button { settings.packetSectionIDs = ids.filter { $0 != id } } label: {
                Image(systemName: "minus.circle.fill")
            }
            .buttonStyle(.plain).foregroundColor(.secondary).help("Remove")
        }
    }

    private func move(_ index: Int, by offset: Int) {
        var list = ids
        let target = index + offset
        guard list.indices.contains(index), list.indices.contains(target) else { return }
        list.swapAt(index, target)
        settings.packetSectionIDs = list
    }

    private func label(for id: String) -> String {
        settings.allDraftDocs.first { $0.id == id }?.displayName ?? id
    }
    private func icon(for id: String) -> String {
        settings.allDraftDocs.first { $0.id == id }?.icon ?? "doc"
    }
    /// A one-line hint for the sections that get bespoke grounding.
    private func groundingNote(for id: String) -> String? {
        switch id {
        case "pocPlan":        return "Grounded in the linked project's success criteria."
        case "actionItemList": return "Reuses the note's own checklist when it has one."
        case "followUpEmail":  return "Shaped by the meeting type."
        default:               return nil
        }
    }
}

private struct DraftTemplatesPane: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var selectedID: String = FollowUpKind.minutes.rawValue
    @State private var text: String = ""
    @State private var name: String = ""

    /// The currently-selected document type, self-healing to the first built-in
    /// if the selected custom template was deleted.
    private var current: DraftDoc {
        settings.allDraftDocs.first { $0.id == selectedID } ?? .builtIn(.minutes)
    }

    private var builtInIsCustomized: Bool {
        if case .builtIn(let k) = current { return settings.hasCustomDraftGuidance(for: k) }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsGroup("Follow-Up Packet") {
                PacketSectionsEditor()
                Divider()
                Toggle("Confirm before generating (uses several cloud-AI calls)", isOn: $settings.packetConfirmBeforeRun)
            }

            SettingsGroup("Document Type") {
                HStack {
                    Picker("Type", selection: $selectedID) {
                        ForEach(settings.groupedDraftDocs, id: \.title) { group in
                            Section(group.title) {
                                ForEach(group.docs) { doc in
                                    Label(doc.displayName, systemImage: doc.icon).tag(doc.id)
                                }
                            }
                        }
                    }
                    .labelsHidden()
                    .onChange(of: selectedID) { _, _ in load() }

                    Button {
                        let id = settings.addUserDraftTemplate(name: "New Document")
                        selectedID = id
                        load()
                    } label: { Image(systemName: "plus") }
                        .help("Add a custom document type")

                    if current.isCustom {
                        Button(role: .destructive) {
                            if case .user(let t) = current {
                                settings.deleteUserDraftTemplate(id: t.id)
                                selectedID = FollowUpKind.minutes.rawValue
                                load()
                            }
                        } label: { Image(systemName: "trash") }
                            .help("Delete this custom document type")
                    }
                }
                if case .builtIn(let k) = current {
                    Text(k.blurb).font(.caption).foregroundColor(.secondary)
                } else {
                    Text("Pick a document type to edit how it's drafted, or add your own. These are the types offered by the note viewer's Draft… menu.")
                        .font(.caption).foregroundColor(.secondary)
                }
            }

            if current.isCustom {
                SettingsGroup("Name") {
                    TextField("Document name", text: $name)
                        .onChange(of: name) { _, newValue in
                            if case .user(let t) = current {
                                settings.updateUserDraftTemplate(id: t.id, name: newValue)
                            }
                        }
                }
            }

            SettingsGroup("\(current.displayName) guidance") {
                MultilineField(text: $text,
                               placeholder: "Describe the recipient, tone, sections, and format the model should use…",
                               minHeight: 200,
                               font: .system(.caption, design: .monospaced))
                    .onChange(of: text) { _, newValue in
                        switch current {
                        case .builtIn(let k): settings.setDraftGuidance(newValue, for: k)
                        case .user(let t):    settings.updateUserDraftTemplate(id: t.id, guidance: newValue)
                        }
                    }
                if !current.isCustom {
                    HStack {
                        Text(builtInIsCustomized ? "Customized" : "Using the built-in default")
                            .font(.caption).foregroundColor(.secondary)
                        Spacer()
                        Button("Reset to Default") {
                            if case .builtIn(let k) = current {
                                settings.setDraftGuidance("", for: k)
                                text = k.guidance
                            }
                        }
                        .disabled(!builtInIsCustomized)
                    }
                }
                Text("The instruction the AI follows for this document — recipient, tone, sections, and format. Draw only from the meeting's notes. Changing it regenerates the document the next time you draft it (each type caches separately).")
                    .font(.caption).foregroundColor(.secondary)
                Divider()
                Text("Looking for a follow-up that adapts to the meeting type (including your custom meeting templates)? That's the note viewer's “Auto — match meeting type” draft, edited under Meeting Templates → follow-up guidance.")
                    .font(.caption).foregroundColor(.secondary)
            }

            // Same shared bundle as Meeting Templates — surfaced here too so
            // email/document templates can be backed up or shared from this pane.
            TemplateTransferSection()
        }
        .onAppear { load() }
    }

    private func load() {
        text = current.guidance
        if case .user(let t) = current { name = t.name }
    }
}

/// Export / import for all custom template data (meeting templates, custom
/// document types, and built-in guidance overrides) as one portable `.json`.
/// Shown in both template panes since one bundle carries everything. Mirrors
/// the Catalog's export/import UX (save/open panel + merge/replace choice).
private struct TemplateTransferSection: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var pendingImportData: Data?
    @State private var showImportChoice = false
    @State private var status: String?

    var body: some View {
        SettingsGroup("Backup & Sharing") {
            HStack {
                Button("Export Templates…") { export() }
                    .disabled(!settings.hasExportableTemplates)
                Button("Import Templates…") { beginImport() }
                Spacer()
            }
            if let status {
                Text(status).font(.caption).foregroundColor(.secondary)
            }
            Text("Save your custom meeting templates, custom document types, and any edits to built-in guidance as one .json file — a backup, or a house style to share with teammates. Built-in templates aren't included; only your additions and edits.")
                .font(.caption).foregroundColor(.secondary)
        }
        .confirmationDialog("Import templates", isPresented: $showImportChoice, titleVisibility: .visible) {
            Button("Merge") { runImport(.merge) }
            Button("Replace", role: .destructive) { runImport(.replace) }
            Button("Cancel", role: .cancel) { pendingImportData = nil }
        } message: {
            Text("Merge adds and updates templates from the file, keeping your others. Replace swaps all your custom template data for the file's.")
        }
    }

    private func export() {
        guard let data = try? settings.exportTemplates() else {
            status = "Nothing to export yet."
            return
        }
        if let s = FilePanels.save(defaultName: "GhostWriter-Templates.json", contentTypes: [.json],
                                   successVerb: "Exported to", failVerb: "Export",
                                   write: { try data.write(to: $0, options: .atomic) }) {
            status = s
        }
    }

    private func beginImport() {
        guard let url = FilePanels.openFile(contentTypes: [.json]),
              let data = try? Data(contentsOf: url) else { return }
        guard settings.isValidTemplateBundle(data) else {
            status = "That file isn't a GhostWriter template export."
            return
        }
        pendingImportData = data
        showImportChoice = true
    }

    private func runImport(_ mode: AppSettings.TemplateImportMode) {
        guard let data = pendingImportData else { return }
        pendingImportData = nil
        do {
            let n = try settings.importTemplates(data, mode: mode)
            status = "Imported \(n) template item\(n == 1 ? "" : "s")."
        } catch {
            status = "Import failed: \(error.localizedDescription)"
        }
    }
}

/// Integrations — outbound event hooks fired when a meeting finishes, so users
/// can wire GhostWriter into their own tools. Both destinations are opt-in and
/// suppressed in Local-only mode (a banner explains why they're disabled).
private struct IntegrationsPane: View {
    @ObservedObject private var settings = AppSettings.shared

    private var scriptIsValid: Bool {
        let p = settings.scriptHookPath.trimmingCharacters(in: .whitespaces)
        return !p.isEmpty && FileManager.default.isExecutableFile(atPath: p)
    }
    private var webhookIsValid: Bool {
        let u = settings.webhookURL.trimmingCharacters(in: .whitespaces)
        return URL(string: u)?.scheme?.lowercased() == "https"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if settings.localOnlyMode {
                Label("Local-only mode is on, so outbound integrations are disabled — they'd send data off your Mac. Turn off Local-only mode in Privacy to use these.",
                      systemImage: "hand.raised.fill")
                    .font(.caption).foregroundColor(.orange)
            }

            SettingsGroup("When a Meeting Finishes") {
                Text("Fire an event the moment a meeting is saved, carrying the note's metadata (title, date, meeting type, linked org/project, tags) — never the audio. Free-text fields are run through your redaction settings first. Use these to post into Notion, Slack, Zapier, or your own scripts.")
                    .font(.caption).foregroundColor(.secondary)
            }

            SettingsGroup("Local Script Hook") {
                Toggle("Run a script when a meeting finishes", isOn: $settings.scriptHookEnabled)
                    .disabled(settings.localOnlyMode)
                Text("Runs your executable with the event JSON on stdin. No network — the easiest option to trust.")
                    .font(.caption).foregroundColor(.secondary)
                HStack {
                    TextField("/path/to/script.sh", text: $settings.scriptHookPath)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!settings.scriptHookEnabled)
                    Button("Choose…") { chooseScript() }
                        .disabled(!settings.scriptHookEnabled)
                }
                if settings.scriptHookEnabled && !settings.scriptHookPath.isEmpty && !scriptIsValid {
                    Label("Not an executable file — run `chmod +x` on it.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundColor(.orange)
                }
            }

            SettingsGroup("Outgoing Webhook") {
                Toggle("POST to a webhook when a meeting finishes", isOn: $settings.webhookEnabled)
                    .disabled(settings.localOnlyMode)
                Text("Sends the event JSON as an HTTP POST. Must be an https URL.")
                    .font(.caption).foregroundColor(.secondary)
                TextField("https://example.com/hooks/ghostwriter", text: $settings.webhookURL)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!settings.webhookEnabled)
                if settings.webhookEnabled && !settings.webhookURL.isEmpty && !webhookIsValid {
                    Label("Enter a valid https:// URL.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundColor(.orange)
                }
            }

            SettingsGroup("Payload") {
                Text("""
                {
                  "event": "meeting.finished",
                  "title": "Acme SSO Scoping",
                  "file": "…/Meeting_2026-07-13.md",
                  "date": "2026-07-13T10:00:00Z",
                  "durationSeconds": 1830,
                  "meetingType": "Solution Scoping",
                  "organisation": "Acme",
                  "project": "SSO Migration",
                  "project": "Platform",
                  "tags": ["meeting", "sso"]
                }
                """)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .textSelection(.enabled)
            }
        }
    }

    private func chooseScript() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose an executable script to run when a meeting finishes."
        if panel.runModal() == .OK, let url = panel.url {
            settings.scriptHookPath = url.path
        }
    }
}

/// Proactive digest — its own pane (it spans meetings, Catalog relationships,
/// and scheduling, so it doesn't belong under notes formatting). The schedule
/// controls stay visible but disabled until the digest is turned on, so users
/// can see what it does before committing.
private struct DigestPane: View {
    @ObservedObject private var settings = AppSettings.shared

    private static let weekdayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    private static func hourLabel(_ h: Int) -> String {
        let period = h < 12 ? "AM" : "PM"
        let hour12 = h % 12 == 0 ? 12 : h % 12
        return "\(hour12) \(period)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsGroup("Proactive Digest") {
                Toggle("Enable digest", isOn: $settings.digestEnabled)
                Text("A scheduled rollup — grouped by relationship — of your recent meetings, open (and overdue) action items, and Catalog relationships that have gone quiet. Opens in an interactive window and is archived as a Digests note. Generated on-device, no API cost. Build one anytime from the menu → Today's Digest.")
                    .font(.caption).foregroundColor(.secondary)
            }

            SettingsGroup("Schedule") {
                HStack {
                    Text("Frequency")
                    Spacer()
                    Picker("", selection: $settings.digestFrequency) {
                        Text("Daily").tag("daily")
                        Text("Weekly").tag("weekly")
                        Text("Monthly").tag("monthly")
                        Text("Yearly").tag("yearly")
                    }
                    .labelsHidden().frame(width: 120)
                }
                if settings.digestFrequency == "weekly" {
                    HStack {
                        Text("Day")
                        Spacer()
                        Picker("", selection: $settings.digestWeekday) {
                            ForEach(Array(Self.weekdayNames.enumerated()), id: \.offset) { i, name in
                                Text(name).tag(i + 1)   // 1 = Sunday
                            }
                        }
                        .labelsHidden().frame(width: 140)
                    }
                }
                HStack {
                    Text("At")
                    Spacer()
                    Picker("", selection: $settings.digestHour) {
                        ForEach(0..<24, id: \.self) { h in Text(Self.hourLabel(h)).tag(h) }
                    }
                    .labelsHidden().frame(width: 100)
                }
                if settings.digestFrequency == "monthly" {
                    Text("Monthly digests run on the 1st.")
                        .font(.caption).foregroundColor(.secondary)
                } else if settings.digestFrequency == "yearly" {
                    Text("Yearly digests run on 1 January.")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            .disabled(!settings.digestEnabled)

            SettingsGroup("Relationships") {
                HStack {
                    Text("Flag relationships quiet after")
                    Spacer()
                    Picker("", selection: $settings.staleRelationshipDays) {
                        ForEach([14, 30, 60, 90], id: \.self) { Text("\($0) days").tag($0) }
                    }
                    .labelsHidden().frame(width: 110)
                }
                Text("An open project with no note in this window is surfaced under \u{201C}Quiet Relationships\u{201D} in the digest.")
                    .font(.caption).foregroundColor(.secondary)
            }
            .disabled(!settings.digestEnabled)
        }
    }
}

/// Manages meeting templates: pick the default, add/rename/delete your own,
/// and edit the section list of whichever is selected. Built-in templates are
/// curated starting points (their sections are editable, resettable); user
/// templates are fully yours (renamable, deletable).
private struct TemplateManager: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var confirmingDelete = false

    private var selected: SummaryTemplate { settings.selectedTemplate }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Meeting template")
                Spacer()
                Picker("", selection: $settings.selectedTemplateID) {
                    ForEach(settings.groupedTemplates, id: \.title) { group in
                        Section(group.title) {
                            ForEach(group.templates) { template in
                                Text(template.displayName).tag(template.id)
                            }
                        }
                    }
                }
                .labelsHidden()
                .frame(width: 180)
                Button {
                    settings.selectedTemplateID = settings.addUserTemplate(name: "New Template")
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add a new template")
                if !selected.isBuiltIn {
                    Button(role: .destructive) {
                        confirmingDelete = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .help("Delete this template")
                }
            }
            if case .builtIn(let t) = selected {
                Text(t.blurb).font(.caption).foregroundColor(.secondary)
            } else {
                Text("Shapes what the summary extracts. Also switchable per meeting from the menu bar.")
                    .font(.caption).foregroundColor(.secondary)
            }

            // Name field for user templates (built-in names are fixed).
            if !selected.isBuiltIn {
                TemplateNameField(id: selected.id, name: selected.displayName)
            }

            TemplateSectionsEditor(template: selected)
            TemplateFollowUpEditor(template: selected)
        }
        .alert("Delete “\(selected.displayName)”?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) { settings.deleteUserTemplate(id: selected.id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This template will be removed. Meeting notes already saved are unaffected.")
        }
    }
}

/// Rename field for a user template, committing on change.
private struct TemplateNameField: View {
    let id: String
    @ObservedObject private var settings = AppSettings.shared
    @State private var name: String

    init(id: String, name: String) {
        self.id = id
        _name = State(initialValue: name)
    }

    var body: some View {
        HStack {
            Text("Name")
            TextField("Template name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onChange(of: name) { _, newValue in
                    settings.updateUserTemplate(id: id, name: newValue)
                }
        }
        // Re-seed when the picker moves to a different user template.
        .onChange(of: id) { _, _ in name = settings.template(withID: id)?.displayName ?? "" }
    }
}

/// Editor for the summary sections of the selected template. Sections are
/// `Heading: instruction` lines. Built-in overrides can be reset to defaults;
/// user templates just save their text.
private struct TemplateSectionsEditor: View {
    let template: SummaryTemplate
    @ObservedObject private var settings = AppSettings.shared
    @State private var text: String = ""

    /// Built-in with no saved override → already at default.
    private var isBuiltInDefault: Bool {
        if case .builtIn(let t) = template {
            return settings.customTemplateSections(for: t) == nil
        }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Sections — one \"Heading: what to extract\" per line.")
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
                if case .builtIn(let t) = template {
                    DefaultResetButton(isDefault: isBuiltInDefault) {
                        settings.setCustomTemplateSections("", for: t)
                        text = t.defaultSectionsText
                    }
                }
            }
            MultilineField(text: $text,
                           placeholder: "## Summary\n## Action Items\n## Decisions",
                           minHeight: 90,
                           font: .system(.caption, design: .monospaced))
                .onChange(of: text) { _, newValue in save(newValue) }
        }
        .onAppear { text = template.sectionsText }
        // Switching the picker re-points this editor at another template.
        .onChange(of: template.id) { _, _ in text = template.sectionsText }
    }

    private func save(_ newValue: String) {
        switch template {
        case .builtIn(let t): settings.setCustomTemplateSections(newValue, for: t)
        case .user(let t):    settings.updateUserTemplate(id: t.id, sections: newValue)
        }
    }
}

/// Editor for the follow-up drafting guidance of the selected template — how
/// the "Draft Follow-up" action shapes its recipient, tone, and content.
/// Built-in overrides can be reset to defaults; user templates just save theirs.
private struct TemplateFollowUpEditor: View {
    let template: SummaryTemplate
    @ObservedObject private var settings = AppSettings.shared
    @State private var text: String = ""

    /// Built-in with no saved override → already at default.
    private var isBuiltInDefault: Bool {
        if case .builtIn(let t) = template {
            return settings.customTemplateFollowUp(for: t) == nil
        }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Auto follow-up shape — how the note viewer's “Auto — match meeting type” draft is written for *this* meeting type (recipient, tone, what to include).")
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
                if case .builtIn(let t) = template {
                    DefaultResetButton(isDefault: isBuiltInDefault) {
                        settings.setCustomTemplateFollowUp("", for: t)
                        text = t.followUpGuidance
                    }
                }
            }
            MultilineField(text: $text,
                           placeholder: "Recipient, tone, and what the follow-up should include…",
                           minHeight: 70,
                           font: .system(.caption, design: .monospaced))
                .onChange(of: text) { _, newValue in save(newValue) }
            Text("For explicit document types (Minutes, Follow-up Email, Status Update, …), see Meetings → Draft Templates.")
                .font(.caption).foregroundColor(.secondary)
        }
        .onAppear { text = template.followUpText }
        // Switching the picker re-points this editor at another template.
        .onChange(of: template.id) { _, _ in text = template.followUpText }
    }

    private func save(_ newValue: String) {
        switch template {
        case .builtIn(let t): settings.setCustomTemplateFollowUp(newValue, for: t)
        case .user(let t):    settings.updateUserTemplate(id: t.id, followUp: newValue)
        }
    }
}

// MARK: - Stats


private struct StatsPane: View {
    @ObservedObject private var stats = UsageStats.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var confirmingReset = false
    @State private var aiCacheCount = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsGroup("Dictation") {
                StatRow(label: "Dictations", value: "\(stats.dictationCount)")
                StatRow(label: "Words typed for you", value: "\(stats.wordsDictated)")
                StatRow(label: "Time spent dictating", value: UsageStats.hoursMinutes(stats.dictationSeconds))
            }

            SettingsGroup("Meetings") {
                StatRow(label: "Meetings recorded", value: "\(stats.meetingCount)")
                StatRow(label: "This week", value: "\(stats.meetingsThisWeek(in: settings.notesFolder))")
                StatRow(label: "Total meeting time", value: UsageStats.hoursMinutes(stats.meetingSeconds))
            }

            SettingsGroup("Estimated Cost") {
                StatRow(label: "This month", value: UsageStats.currency(stats.costThisMonthUSD))
                StatRow(label: "Estimated Groq spend (all time)", value: UsageStats.currency(stats.estimatedCostUSD))
                StatRow(label: "Audio transcribed", value: UsageStats.hoursMinutes(stats.audioSecondsTranscribed))
                StatRow(label: "LLM tokens (in / out)", value: "\(stats.inputTokens) / \(stats.outputTokens)")
                Text("A rough estimate from local counters — actual billing on the Groq console is authoritative. Prices drift, so they're editable:")
                    .font(.caption).foregroundColor(.secondary)
                PriceField(label: "Audio $/hour", value: $settings.priceAudioPerHour, defaultValue: AppSettings.Default.priceAudioPerHour)
                PriceField(label: "Input $/M tokens", value: $settings.priceInputPerMTok, defaultValue: AppSettings.Default.priceInputPerMTok)
                PriceField(label: "Output $/M tokens", value: $settings.priceOutputPerMTok, defaultValue: AppSettings.Default.priceOutputPerMTok)
            }

            SettingsGroup("Monthly Budget") {
                PriceField(label: "Budget ($/month, 0 = off)", value: $settings.monthlyBudgetUSD, defaultValue: AppSettings.Default.monthlyBudgetUSD)
                if let fraction = stats.budgetFraction {
                    ProgressView(value: min(fraction, 1.0)) {
                        HStack {
                            Text("\(UsageStats.currency(stats.costThisMonthUSD)) of \(UsageStats.currency(settings.monthlyBudgetUSD))")
                            Spacer()
                            Text("\(Int(fraction * 100))%")
                                .foregroundColor(stats.isOverBudget ? .red : .secondary)
                        }
                        .font(.caption)
                    }
                    .tint(stats.isOverBudget ? .red : .accentColor)
                    if stats.isOverBudget {
                        Label("Over budget this month — spend continues; this is a warning only.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundColor(.orange)
                    }
                }
                Text("A soft cap: when this month's estimate crosses the budget, GhostWriter shows a warning (and notifies once). It never blocks transcription. Resets on the 1st.")
                    .font(.caption).foregroundColor(.secondary)
            }

            SettingsGroup("Maintenance") {
                HStack {
                    Text("Counters are stored locally and never leave this Mac.")
                        .font(.caption).foregroundColor(.secondary)
                    Spacer()
                    Button("Reset Stats…", role: .destructive) { confirmingReset = true }
                        .confirmationDialog("Reset all usage statistics?", isPresented: $confirmingReset) {
                            Button("Reset", role: .destructive) { stats.reset() }
                            Button("Cancel", role: .cancel) {}
                        }
                }
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("AI summary cache")
                        Text("Reuses generated note summaries, relationship digests, and follow-up drafts to save tokens. Rebuilds automatically. \(aiCacheCount) cached.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("Clear Cache") {
                        AICache.shared.clear()
                        aiCacheCount = AICache.shared.count
                    }
                    .disabled(aiCacheCount == 0)
                }
                HStack {
                    Text("Cache limit (entries)")
                    Spacer()
                    Picker("", selection: $settings.aiCacheLimit) {
                        ForEach([100, 250, 500, 1000, 2000], id: \.self) { Text("\($0)").tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 100)
                    DefaultResetButton(isDefault: settings.aiCacheLimit == AppSettings.Default.aiCacheLimit) {
                        settings.aiCacheLimit = AppSettings.Default.aiCacheLimit
                    }
                }
            }
            .onAppear { aiCacheCount = AICache.shared.count }
        }
    }
}

private struct StatRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .monospacedDigit()
                .foregroundColor(.secondary)
        }
    }
}

/// Editable USD price with reset-to-default.
private struct PriceField: View {
    let label: String
    @Binding var value: Double
    let defaultValue: Double

    var body: some View {
        HStack {
            Text(label).font(.caption)
            Spacer()
            TextField("", value: $value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 90)
                .multilineTextAlignment(.trailing)
            DefaultResetButton(isDefault: value == defaultValue) { value = defaultValue }
        }
    }
}

// MARK: - Privacy

private struct PrivacyPane: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsGroup("Network") {
                Toggle("Local-only mode (never contact the network)", isOn: $settings.localOnlyMode)
                Text("Transcribe on-device (Apple Speech) and run AI on-device too — summaries and follow-ups via Apple Intelligence, and entity/topic tags via macOS NaturalLanguage. No API cost and nothing leaves this Mac. Lower transcription accuracy than the cloud.")
                    .font(.caption).foregroundColor(.secondary)
                Label {
                    Text(AppleIntelligence.isAvailable
                         ? "Apple Intelligence is available — on-device summaries are on."
                         : "Apple Intelligence unavailable: \(AppleIntelligence.unavailableReason ?? "") On-device tagging still works; summaries need the cloud.")
                } icon: {
                    Image(systemName: AppleIntelligence.isAvailable ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                }
                .font(.caption)
                .foregroundColor(AppleIntelligence.isAvailable ? .secondary : .orange)
            }

            SettingsGroup("Redaction") {
                Toggle("Redact sensitive info from transcripts", isOn: $settings.redactionEnabled)
                Text("Replaces matches with labels (e.g. [redacted email]) in the transcribed text before it's typed, saved to notes, or sent for polishing/summaries — so the original is never stored or seen by the LLM. Covers dictation, quick notes, and meetings. Note: audio is still sent to Groq for transcription; to keep audio on-device too, also enable Local-only mode.")
                    .font(.caption).foregroundColor(.secondary)
                if settings.redactionEnabled {
                    Toggle("Email addresses", isOn: $settings.redactEmails)
                    Toggle("Phone numbers", isOn: $settings.redactPhones)
                    Toggle("Long number sequences (cards, account numbers)", isOn: $settings.redactNumbers)
                }
            }
        }
    }
}

// MARK: - Diagnostics

private struct DiagnosticsPane: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var log = DiagnosticsLog.shared

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .medium
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsGroup("Notifications") {
                Toggle("Notify me when something fails", isOn: $settings.errorNotifications)
                Text("Transcription, polishing, summary, and follow-up failures post a notification and appear below. The most recent error is also shown at the top of the menu bar menu until dismissed.")
                    .font(.caption).foregroundColor(.secondary)
            }

            SettingsGroup("Recent Errors") {
                if log.entries.isEmpty {
                    Text("No errors recorded this session. 🎉")
                        .font(.caption).foregroundColor(.secondary)
                } else {
                    ForEach(log.entries) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.message)
                                .font(.caption)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(Self.timeFormatter.string(from: entry.date))
                                .font(.caption2).foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Divider()
                    }
                    HStack {
                        Spacer()
                        Button("Clear", role: .destructive) { log.clear() }
                    }
                }
            }

            SettingsGroup("Reliability") {
                Text("When a Groq request fails, GhostWriter automatically retries meeting segments and — if offline fallback is on (AI & Models → On-Device & Fallback) — transcribes on-device so you don't lose audio. Detailed logs are in Console.app under the “GhostWriter” subsystem.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - Permissions

private struct PermissionsPane: View {
    private let permissionGuard = PermissionGuard()
    @State private var hasMic = false
    @State private var hasA11y = false
    @State private var hasSysAudio: Bool? = nil
    @State private var hasAutomation: Bool? = nil
    @State private var hasReminders: Bool? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsGroup("Status") {
                PermissionRow(
                    name: "Microphone",
                    granted: hasMic,
                    detail: "Transcribes your speech."
                ) { permissionGuard.openMicrophoneSettings() }

                Divider()

                PermissionRow(
                    name: "System Audio Recording",
                    granted: hasSysAudio,
                    detail: "Captures the other participants in meetings."
                ) { permissionGuard.openSystemAudioSettings() }

                Divider()

                PermissionRow(
                    name: "Accessibility",
                    granted: hasA11y,
                    detail: "Push-to-talk hotkey and typing at your cursor."
                ) { permissionGuard.openAccessibilitySettings() }

                Divider()

                PermissionRow(
                    name: "Automation (default browser)",
                    granted: hasAutomation,
                    detail: "Optional — reads the active browser tab's address for per-site styling (Settings → Dictation → Browser Tab Styles). Prompted on first use; status shown for your default browser.",
                    optional: true
                ) { permissionGuard.openAutomationSettings() }

                Divider()

                PermissionRow(
                    name: "Reminders",
                    granted: hasReminders,
                    detail: "Optional — lets you export meeting action items to the Reminders app (Catalog → Action Items). Prompted on first export.",
                    optional: true
                ) { permissionGuard.openRemindersSettings() }
            }

            SettingsGroup("Maintenance") {
                HStack {
                    Text("Revoke all grants and relaunch so macOS prompts again. Use this if a permission is stuck after an update.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Reset All Permissions…", role: .destructive) {
                        NotificationCenter.default.post(name: .resetAllPermissions, object: nil)
                    }
                }
            }

            Text("Changes made in System Settings are picked up automatically.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .onAppear(perform: refresh)
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in refresh() }
    }

    private func refresh() {
        hasMic = permissionGuard.hasMicrophonePermission
        hasA11y = permissionGuard.hasAccessibilityPermission
        hasSysAudio = permissionGuard.hasSystemAudioPermission
        hasAutomation = permissionGuard.automationStatusForDefaultBrowser()
        hasReminders = permissionGuard.remindersStatus()
    }
}

private struct PermissionRow: View {
    let name: String
    let granted: Bool?     // nil = not queryable
    let detail: String
    var optional: Bool = false   // optional permissions render neutrally when nil
    let openSettings: () -> Void

    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                Text(detail).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Button("Open Settings…", action: openSettings)
        }
    }

    private var icon: String {
        switch granted {
        case true:  return "checkmark.circle.fill"
        case false: return "xmark.circle.fill"
        default:    return optional ? "minus.circle" : "questionmark.circle.fill"
        }
    }
    private var color: Color {
        switch granted {
        case true:  return .green
        case false: return .red
        default:    return .secondary
        }
    }
}

// MARK: - Reusable Controls

/// A multi-line text box with a greyed placeholder shown while it's empty —
/// SwiftUI's `TextEditor` has no prompt of its own, so an empty field otherwise
/// reads as a broken blank box. Centralizes the monospaced font + border styling
/// every settings editor was hand-rolling. Grows past `minHeight` as text wraps.
private struct MultilineField: View {
    @Binding var text: String
    var placeholder: String = ""
    var minHeight: CGFloat = 54
    var font: Font = .system(.caption, design: .monospaced)

    var body: some View {
        TextEditor(text: $text)
            .font(font)
            .frame(minHeight: minHeight)
            // Placeholder sits on top but only while empty (so it never covers
            // real text) and ignores hits so clicks fall through to the editor.
            .overlay(alignment: .topLeading) {
                if text.isEmpty && !placeholder.isEmpty {
                    Text(placeholder)
                        .font(font)
                        .foregroundColor(.secondary.opacity(0.5))
                        .padding(.horizontal, 5)
                        .padding(.top, 8)
                        .allowsHitTesting(false)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15)))
    }
}

/// Card-style settings group with a header, mimicking System Settings.
private struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
        }
    }
}

/// Slider for dBFS thresholds with a live value readout and a reset-to-default button.
private struct ThresholdSlider: View {
    let title: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    let defaultValue: Float
    let help: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%.0f dBFS", value))
                    .monospacedDigit()
                    .foregroundColor(.secondary)
                DefaultResetButton(isDefault: value == defaultValue) { value = defaultValue }
            }
            Slider(value: $value, in: range, step: 1)
            if let help {
                Text(help).font(.caption).foregroundColor(.secondary)
            }
        }
    }
}

/// Slider for durations (seconds) with a live value readout and a reset button.
private struct DurationSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let unit: String
    let defaultValue: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%.1f %@", value, unit))
                    .monospacedDigit()
                    .foregroundColor(.secondary)
                DefaultResetButton(isDefault: value == defaultValue) { value = defaultValue }
            }
            Slider(value: $value, in: range, step: step)
        }
    }
}

/// Small circular-arrow button, disabled when the value already matches the default.
private struct DefaultResetButton: View {
    let isDefault: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.counterclockwise")
        }
        .buttonStyle(.borderless)
        .disabled(isDefault)
        .help("Reset to default")
    }
}

private struct ResetToDefaultsRow: View {
    @State private var confirming = false

    var body: some View {
        HStack {
            Text("Restore every setting to its default value.")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Button("Reset All Settings…", role: .destructive) { confirming = true }
                .confirmationDialog("Reset all settings to defaults?", isPresented: $confirming) {
                    Button("Reset", role: .destructive) {
                        AppSettings.shared.resetToDefaults()
                        NotificationCenter.default.post(name: .settingsDidReset, object: nil)
                    }
                    Button("Cancel", role: .cancel) {}
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
