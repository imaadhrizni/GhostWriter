import SwiftUI

// MARK: - System & Account Settings Panes
//
// Stats / Estimated cost / Budget, Privacy (network + redaction), Diagnostics
// (error log), and Permissions. Split out of `SettingsView.swift`; they rely on
// the shared controls in `SettingsControls.swift`.

// MARK: - Stats

struct StatsPane: View {
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

            SettingsGroup("AI Activity") {
                AIActivityView()
                Text("Live view of the shared request gate — how many Groq calls are in flight or queued, and whether a rate-limit backoff is active. Chat and transcription have separate limits.")
                    .font(.caption).foregroundColor(.secondary)
            }

            SettingsGroup("API Call Log") {
                APICallLogSummary()
                Text("A full per-call history of every Groq request — feature, model, tokens or audio, time, and estimated cost — for auditing exactly what hit the API and from where.")
                    .font(.caption).foregroundColor(.secondary)
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

struct StatRow: View {
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
struct PriceField: View {
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

struct PrivacyPane: View {
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

struct DiagnosticsPane: View {
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

struct PermissionsPane: View {
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

struct PermissionRow: View {
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
