import SwiftUI

// MARK: - Writing Styles (dictation output shaping)

struct WritingStylesPane: View {
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
                Text("Force a style — built-in or custom — for a specific app. Use “Add app…” to grab a running app's ID without hunting for it.")
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

            SettingsGroup("Text Insertion") {
                Text("Some apps (browsers, Slack, VS Code, Claude, and other Chromium/Electron apps) don't accept text through the normal insertion path, so GhostWriter pastes into them instead. The common ones are handled automatically; add any others here — one bundle ID per line.")
                    .font(.caption).foregroundColor(.secondary)
                MultilineField(text: $settings.pasteOnlyApps,
                               placeholder: "com.example.someElectronApp\ncom.example.another",
                               minHeight: 60,
                               font: .system(.caption, design: .monospaced))
            }
        }
    }
}

/// Row-based editor for browser-tab style rules. The host stays free text, but
/// the style is a Picker over the closed set of built-in + custom styles, so it
/// can't be mistyped. Backed by the same newline `host: style` string, with a
/// collapsible bulk-edit box; a bulk edit re-hydrates the rows and vice-versa.
struct DomainStyleEditor: View {
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
struct AppProfileEditor: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var rules: [Rule] = []
    @State private var showBulk = false

    private struct Rule: Identifiable, Equatable {
        let id = UUID()
        var bundleID: String
        var style: String
    }

    private var defaultStyle: String { settings.dictationStyleKeys.first?.key ?? "general" }

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
        var opts = settings.dictationStyleKeys
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
struct VoiceCommandEditor: View {
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
struct DictationStyleManager: View {
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
struct DictationStyleNameField: View {
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
struct DictationStyleEditor: View {
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

