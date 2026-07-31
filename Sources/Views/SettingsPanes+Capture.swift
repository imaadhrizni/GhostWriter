import SwiftUI

// MARK: - Dictation

struct DictationPane: View {
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

struct QuickNotesPane: View {
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

struct ShortcutsPane: View {
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
struct ShortcutBindingRow: View {
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

struct ShortcutRow: View {
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

struct MeetingPane: View {
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

