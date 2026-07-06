import SwiftUI
import AVFoundation
import ServiceManagement

// MARK: - Window Controller

final class SettingsWindowController: NSWindowController {
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.center()
        window.title = "GhostWriter Settings"
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified

        self.init(window: window)

        let contentView = NSHostingView(rootView: SettingsView())
        window.contentView = contentView
    }

    func showAndActivate() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.center()
    }
}

// MARK: - Sections

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general     = "General"
    case dictation   = "Dictation"
    case quickNotes  = "Quick Notes"
    case meeting     = "Recording"
    case notes       = "Notes & Summaries"
    case privacy     = "Privacy"
    case permissions = "Permissions"
    case shortcuts   = "Shortcuts"
    case stats       = "Usage & Cost"
    case diagnostics = "Diagnostics"
    case about       = "About"

    var id: String { rawValue }

    /// Sidebar layout: related panes grouped under headers, the way
    /// System Settings clusters its domains.
    static let sidebarGroups: [(title: String?, sections: [SettingsSection])] = [
        (nil,                  [.general]),
        ("Capture",            [.dictation, .quickNotes]),
        ("Meetings",           [.meeting, .notes]),
        ("Privacy & Security", [.privacy, .permissions]),
        ("App",                [.shortcuts, .stats, .diagnostics, .about]),
    ]

    var icon: String {
        switch self {
        case .general:     return "gearshape.fill"
        case .dictation:   return "mic.fill"
        case .quickNotes:  return "square.and.pencil"
        case .meeting:     return "person.2.wave.2.fill"
        case .notes:       return "doc.text.fill"
        case .privacy:     return "hand.raised.fill"
        case .permissions: return "lock.shield.fill"
        case .shortcuts:   return "command"
        case .stats:       return "chart.bar.fill"
        case .diagnostics: return "stethoscope"
        case .about:       return "info.circle.fill"
        }
    }

    var iconColor: Color {
        switch self {
        case .general:     return .gray
        case .dictation:   return .blue
        case .quickNotes:  return .yellow
        case .meeting:     return .purple
        case .notes:       return .indigo
        case .privacy:     return .pink
        case .permissions: return .green
        case .shortcuts:   return .orange
        case .stats:       return .teal
        case .diagnostics: return .red
        case .about:       return .secondary
        }
    }
}

// MARK: - Settings Root (System Settings-style sidebar)

struct SettingsView: View {
    @State private var selection: SettingsSection = .general

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(SettingsSection.sidebarGroups, id: \.sections.first!.id) { group in
                    Section {
                        ForEach(group.sections) { section in
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
                    } header: {
                        if let title = group.title { Text(title) }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 195, max: 230)
        } detail: {
            ScrollView {
                Group {
                    switch selection {
                    case .general:     GeneralPane()
                    case .dictation:   DictationPane()
                    case .quickNotes:  QuickNotesPane()
                    case .meeting:     MeetingPane()
                    case .notes:       MeetingNotesPane()
                    case .privacy:     PrivacyPane()
                    case .permissions: PermissionsPane()
                    case .shortcuts:   ShortcutsPane()
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
        .frame(width: 660, height: 480)
    }
}

// MARK: - General

private struct GeneralPane: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var hasAPIKey = KeychainService.groqAPIKey() != nil
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

    private static let transcriptionModels = [
        "whisper-large-v3",
        "whisper-large-v3-turbo",
        "distil-whisper-large-v3-en",
    ]
    private static let polishingModels = [
        "llama-3.3-70b-versatile",
        "llama-3.1-8b-instant",
        "openai/gpt-oss-120b",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsGroup("Groq API") {
                HStack {
                    Image(systemName: hasAPIKey ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundColor(hasAPIKey ? .green : .orange)
                    Text(hasAPIKey ? "API key configured" : "No API key set")
                    Spacer()
                    Button("Change…") {
                        NotificationCenter.default.post(name: .showAPIKeyWindow, object: nil)
                    }
                }

                Divider()

                ModelField(
                    title: "Transcription model",
                    presets: Self.transcriptionModels,
                    defaultValue: AppSettings.Default.transcriptionModel,
                    value: $settings.transcriptionModel
                )

                Divider()

                ModelField(
                    title: "Polishing model",
                    presets: Self.polishingModels,
                    defaultValue: AppSettings.Default.polishingModel,
                    value: $settings.polishingModel
                )

                Divider()

                Toggle("Offline fallback (Apple on-device recognition)", isOn: $settings.offlineFallback)
                Text("If Groq can't be reached, transcribe on-device instead of failing — applies to dictation, quick notes, and meetings. Lower accuracy and no AI polishing or summaries (transcription only), but zero network. Triggers on connectivity errors, not on API-key or server errors.")
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

            SettingsGroup("Startup") {
                Toggle("Start GhostWriter at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        setLaunchAtLogin(enabled)
                    }
                Text("Automatically open GhostWriter in the menu bar when you log in to your Mac.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            SettingsGroup("Maintenance") {
                ResetToDefaultsRow()
            }
        }
        .onAppear {
            hasAPIKey = KeychainService.groqAPIKey() != nil
            launchAtLogin = SMAppService.mainApp.status == .enabled
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

/// Date format used across the menu and Notes Assistant, with presets,
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
            Text("Preview: \(DateDisplay.preview(settings.uiDateFormat).isEmpty ? "—" : DateDisplay.preview(settings.uiDateFormat))  ·  Unicode date pattern (dd MMM yyyy). Applies to the menu and Notes Assistant; note filenames are unaffected.")
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
                Text("Hold to record, release to transcribe and type at your cursor. Takes effect immediately.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            SettingsGroup("History") {
                Toggle("Keep recent dictations", isOn: $settings.dictationHistoryEnabled)
                    .onChange(of: settings.dictationHistoryEnabled) { _, enabled in
                        if !enabled {
                            NotificationCenter.default.post(name: .dictationHistoryDisabled, object: nil)
                        }
                    }
                Text("Shown in the menu bar for copy and ⌃⌥V recall. Kept in memory only — cleared when disabled or when the app quits.")
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

            SettingsGroup("Transcription Quality") {
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
                Divider()
                HStack {
                    Toggle("Voice commands", isOn: $settings.voiceCommandsEnabled)
                    Spacer()
                    DefaultResetButton(isDefault: settings.voiceCommandRules == AppSettings.Default.voiceCommandRules) {
                        settings.voiceCommandRules = AppSettings.Default.voiceCommandRules
                    }
                }
                Text("Say \"new paragraph\", \"comma\", \"scratch that\", or \"all caps … end caps\" while dictating.")
                    .font(.caption).foregroundColor(.secondary)
                if settings.voiceCommandsEnabled {
                    Text("Rules — one per line, \"spoken phrase → effect\". Edit freely; the polishing model follows them.")
                        .font(.caption).foregroundColor(.secondary)
                    TextEditor(text: $settings.voiceCommandRules)
                        .font(.system(.caption, design: .monospaced))
                        .frame(height: 90)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                }
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
                Text("ISO 639-1 code hint for Whisper (en, de, ta, si, …). Leave as en unless you dictate in another language.")
                    .font(.caption).foregroundColor(.secondary)

                Divider()

                Text("Custom vocabulary").font(.caption.bold())
                TextEditor(text: $settings.vocabulary)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 54)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15)))
                Text("Names, acronyms, jargon — comma or newline separated. Whisper biases toward these terms (e.g. WSO2, Sivanoly, Choreo).")
                    .font(.caption).foregroundColor(.secondary)

                Divider()

                Text("Replacements").font(.caption.bold())
                TextEditor(text: $settings.replacements)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 54)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15)))
                Text("Applied after transcription, one rule per line: wrong => right (e.g. west of two => WSO2).")
                    .font(.caption).foregroundColor(.secondary)
            }

            SettingsGroup("Writing Styles") {
                DictationStyleManager()
            }

            SettingsGroup("Per-App Style Overrides") {
                TextEditor(text: $settings.appProfiles)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 54)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15)))
                Text("Force a built-in style per app, one per line: bundle.id: style — styles: messaging, email, code, browser, notes, general (e.g. com.tinyspeck.slackmacgap: messaging). Custom styles apply via the default above.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
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
            TextEditor(text: $text)
                .font(.system(.caption, design: .monospaced))
                .frame(height: 90)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
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
                Text("Kept apart from meeting notes so meeting history and the Notes Assistant stay meetings-only. Open the latest file via menu bar → Notes → Open Today's Quick Notes.")
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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsGroup("Dictation") {
                ShortcutRow(keys: "Hold \(pttKeyName)", detail: "Push-to-talk — record while held, type on release")
                ShortcutRow(keys: "Esc", detail: "Cancel an in-progress dictation (types nothing)")
                ShortcutRow(keys: "⌃⌥V", detail: "Type the most recent dictation again")
                ShortcutRow(keys: "⌃⌥J", detail: "Quick note — dictate into today's notes file (press again to save, Esc to cancel)")
            }

            SettingsGroup("Meeting Mode") {
                ShortcutRow(keys: "⌃⌥M", detail: "Start / stop Meeting Mode")
                ShortcutRow(keys: "⌃⌥P", detail: "Pause / resume meeting transcription")
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
                Divider()
                Toggle("Label distinct speakers (experimental)", isOn: $settings.diarizationEnabled)
                Text("Fingerprints each voice (pitch and timbre) and clusters segments, labeling remote voices Them / Them 2 / Them 3. On-device and lightweight — similar-sounding voices may still merge. Use Meeting Notes ▸ Rename Speakers… to give them real names per meeting.")
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
                }
            }

            SettingsGroup("Intelligence") {
                TemplateManager()
                Divider()
                Toggle("Append AI summary when a meeting ends", isOn: $settings.summariesEnabled)
                Text("Adds the template's sections to the notes file.")
                    .font(.caption).foregroundColor(.secondary)
                Divider()
                Toggle("Append action items", isOn: $settings.actionItemsEnabled)
                Text("Adds an Action Items checklist (with owners when identifiable). Also feeds the Notes Assistant's Action Items tab.")
                    .font(.caption).foregroundColor(.secondary)
                Divider()
                Toggle("Auto-tag topics into front-matter", isOn: $settings.autoTagging)
                Text("After summarizing, extract 3–6 topic tags and merge them into the note's YAML front-matter (great for Obsidian/Notion graphs). Requires front-matter enabled and network access.")
                    .font(.caption).foregroundColor(.secondary)
                Divider()
                Toggle("Notify when notes are saved", isOn: $settings.notifyOnMeetingEnd)
            }

            SettingsGroup("Notes Assistant") {
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
                Text("How many recent meetings full-text search and \"All meetings\" Ask scan. Higher reaches further back but is slower on large archives.")
                    .font(.caption).foregroundColor(.secondary)
                Divider()
                HStack {
                    Text("Action items from last")
                    Spacer()
                    Picker("", selection: $settings.actionItemsLookback) {
                        ForEach([5, 10, 20, 50], id: \.self) { Text("\($0) meetings").tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                    DefaultResetButton(isDefault: settings.actionItemsLookback == AppSettings.Default.actionItemsLookback) {
                        settings.actionItemsLookback = AppSettings.Default.actionItemsLookback
                    }
                }
            }
        }
    }

    private func pickNotesFolder() {
        if let url = chooseFolder(startingAt: settings.notesFolder) {
            settings.notesFolder = url
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
                    ForEach(settings.allTemplates) { template in
                        Text(template.displayName).tag(template.id)
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
            Text("Shapes what the summary extracts — Standup gets Updates/Blockers, Customer Call gets Needs/Objections/Commitments, and so on. Also switchable per meeting from the menu bar.")
                .font(.caption).foregroundColor(.secondary)

            // Name field for user templates (built-in names are fixed).
            if !selected.isBuiltIn {
                TemplateNameField(id: selected.id, name: selected.displayName)
            }

            TemplateSectionsEditor(template: selected)
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
            TextEditor(text: $text)
                .font(.system(.caption, design: .monospaced))
                .frame(height: 90)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
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

// MARK: - Stats

private struct StatsPane: View {
    @ObservedObject private var stats = UsageStats.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var confirmingReset = false

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
                StatRow(label: "Estimated Groq spend", value: UsageStats.currency(stats.estimatedCostUSD))
                StatRow(label: "Audio transcribed", value: UsageStats.hoursMinutes(stats.audioSecondsTranscribed))
                StatRow(label: "LLM tokens (in / out)", value: "\(stats.inputTokens) / \(stats.outputTokens)")
                Text("A rough estimate from local counters — actual billing on the Groq console is authoritative. Prices drift, so they're editable:")
                    .font(.caption).foregroundColor(.secondary)
                PriceField(label: "Audio $/hour", value: $settings.priceAudioPerHour, defaultValue: AppSettings.Default.priceAudioPerHour)
                PriceField(label: "Input $/M tokens", value: $settings.priceInputPerMTok, defaultValue: AppSettings.Default.priceInputPerMTok)
                PriceField(label: "Output $/M tokens", value: $settings.priceOutputPerMTok, defaultValue: AppSettings.Default.priceOutputPerMTok)
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
            }
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
                Text("Transcribe entirely on-device and skip every cloud step — no polishing, summaries, auto-tags, or follow-up drafts, and no API cost. Lower transcription accuracy; nothing leaves this Mac.")
                    .font(.caption).foregroundColor(.secondary)
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
                Text("When a Groq request fails, GhostWriter automatically retries meeting segments and — if offline fallback is on (General) — transcribes on-device so you don't lose audio. Detailed logs are in Console.app under the “GhostWriter” subsystem.")
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
    }
}

private struct PermissionRow: View {
    let name: String
    let granted: Bool?     // nil = not queryable
    let detail: String
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
        default:    return "questionmark.circle.fill"
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
