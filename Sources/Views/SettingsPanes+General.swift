import SwiftUI
import ServiceManagement

// MARK: - General

struct AIPane: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var hasAPIKey = KeychainService.groqAPIKey() != nil

    private static let transcriptionModels = [
        "whisper-large-v3",
        "whisper-large-v3-turbo",
        "distil-whisper-large-v3-en",
    ]
    private static let polishingModels = [
        "openai/gpt-oss-120b",                          // reasoning model — default; answer arrives via the reasoning field
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
                    role: .transcription,
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
                    role: .summary,
                    presets: Self.polishingModels,
                    defaultValue: AppSettings.Default.polishingModel,
                    value: $settings.polishingModel
                )

                Divider()

                ModelField(
                    title: "Lightweight-tasks model",
                    role: .lightweight,
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

struct GeneralPane: View {
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
struct BackupRow: View {
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
struct AutomaticBackupRow: View {
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
struct ModelField: View {
    let title: String
    let role: ModelResolver.Role
    let presets: [String]
    let defaultValue: String
    @Binding var value: String

    /// Bumped once the live catalog is fetched, so the availability note
    /// re-evaluates. ModelResolver isn't observable, hence the manual tick.
    @State private var catalogTick = 0

    /// Menu options: Groq's live catalog for this role when we have it (so every
    /// pick is a model that actually exists and won't be silently rerouted),
    /// otherwise the static presets. The current value is always included so a
    /// custom or not-yet-listed id stays selectable.
    private var options: [String] {
        _ = catalogTick
        let live = ModelResolver.shared.catalogModels(for: role)
        let base = live.isEmpty ? presets : live
        let cur = value.trimmingCharacters(in: .whitespaces)
        return cur.isEmpty || base.contains(cur) ? base : base + [cur]
    }

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
                    ForEach(options, id: \.self) { preset in
                        Button {
                            value = preset
                        } label: {
                            let desc = ModelResolver.describe(preset)
                            if desc.isEmpty {
                                Text(preset)
                            } else {
                                // Two-line menu item: id on top, blurb beneath.
                                Text(preset)
                                Text(desc)
                            }
                        }
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
            } else {
                // Blurb for the current selection, so the trade-off is visible
                // without opening the menu.
                let desc = ModelResolver.describe(value.trimmingCharacters(in: .whitespaces))
                if !desc.isEmpty {
                    Text(desc).font(.caption).foregroundColor(.secondary)
                }
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
struct ModelAvailabilityView: View {
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
struct DateFormatField: View {
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

