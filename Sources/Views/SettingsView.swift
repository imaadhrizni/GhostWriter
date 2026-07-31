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
