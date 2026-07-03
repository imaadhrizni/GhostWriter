import SwiftUI
import AVFoundation

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
    case meeting     = "Meeting Mode"
    case shortcuts   = "Shortcuts"
    case stats       = "Stats"
    case permissions = "Permissions"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .general:     return "gearshape.fill"
        case .dictation:   return "mic.fill"
        case .meeting:     return "person.2.wave.2.fill"
        case .shortcuts:   return "command"
        case .stats:       return "chart.bar.fill"
        case .permissions: return "lock.shield.fill"
        }
    }

    var iconColor: Color {
        switch self {
        case .general:     return .gray
        case .dictation:   return .blue
        case .meeting:     return .purple
        case .shortcuts:   return .orange
        case .stats:       return .teal
        case .permissions: return .green
        }
    }
}

// MARK: - Settings Root (System Settings-style sidebar)

struct SettingsView: View {
    @State private var selection: SettingsSection = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selection) { section in
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
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 190, max: 220)
        } detail: {
            ScrollView {
                Group {
                    switch selection {
                    case .general:     GeneralPane()
                    case .dictation:   DictationPane()
                    case .meeting:     MeetingPane()
                    case .shortcuts:   ShortcutsPane()
                    case .stats:       StatsPane()
                    case .permissions: PermissionsPane()
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
            }

            SettingsGroup("Microphone") {
                Toggle("Prefer built-in microphone", isOn: $settings.preferBuiltInMic)
                Text("Off: capture from the system default input (e.g. your headset mic). On: always use the Mac's built-in mic — keeps Bluetooth headphones (AirPods) in high-quality audio, since using their mic forces the low-quality call profile and shifts volume. Applies to dictation and meetings.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            SettingsGroup("Maintenance") {
                ResetToDefaultsRow()
            }
        }
        .onAppear { hasAPIKey = KeychainService.groqAPIKey() != nil }
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
                Toggle("Offline fallback (Apple on-device recognition)", isOn: $settings.offlineFallback)
                Text("When Groq is unreachable, transcribe on-device instead of failing. Lower accuracy, zero network.")
                    .font(.caption).foregroundColor(.secondary)

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

            SettingsGroup("Per-App Style Overrides") {
                TextEditor(text: $settings.appProfiles)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 54)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15)))
                Text("Force a polishing style per app, one per line: bundle.id: style — styles: messaging, email, code, browser, notes, general (e.g. com.tinyspeck.slackmacgap: casual → use messaging).")
                    .font(.caption).foregroundColor(.secondary)
            }
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

            SettingsGroup("Notes") {
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
            }

            SettingsGroup("Intelligence") {
                Toggle("Append AI summary when a meeting ends", isOn: $settings.summariesEnabled)
                Text("Adds TL;DR and decisions to the notes file.")
                    .font(.caption).foregroundColor(.secondary)
                Divider()
                Toggle("Append action items", isOn: $settings.actionItemsEnabled)
                Text("Adds an Action Items section (with owners when identifiable). Also feeds the Notes Assistant's Action Items tab.")
                    .font(.caption).foregroundColor(.secondary)
                Divider()
                Toggle("Notify when notes are saved", isOn: $settings.notifyOnMeetingEnd)
                Divider()
                Toggle("Obsidian/Notion front-matter", isOn: $settings.frontMatterEnabled)
                Text("Prepends YAML metadata (title, date, tags) to each notes file.")
                    .font(.caption).foregroundColor(.secondary)
                Divider()
                Toggle("Label distinct speakers (experimental)", isOn: $settings.diarizationEnabled)
                Text("Guesses speaker turns from pauses and loudness — labels remote voices Them / Them 2. Best effort, not true voice recognition.")
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

    private func pickNotesFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = settings.notesFolder
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            settings.notesFolder = url
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
}

private extension String {
    func abbreviatingHome() -> String {
        (self as NSString).abbreviatingWithTildeInPath
    }
}
