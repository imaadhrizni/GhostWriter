import SwiftUI
import AppKit

// MARK: - Live Meeting Assistant
//
// A rolling, in-meeting brief. While a meeting runs, this periodically reads
// the live transcript and asks the polishing model for a compact TL;DR plus
// the open action items so far, shown in a small floating panel at the top-
// right of the screen. Cost-aware: only re-briefs when enough new transcript
// has accumulated, sends just the recent tail, and is fully opt-in
// (Settings → Meetings → Notes & Summaries) and never runs in Local-only mode.

@MainActor
final class LiveMeetingAssistant: ObservableObject {
    static let shared = LiveMeetingAssistant()

    @Published private(set) var brief = TextPolisher.LiveBrief(tldr: [], actions: [])
    @Published private(set) var updating = false
    @Published private(set) var lastUpdate: Date?

    /// Live agenda coverage — user-typed items plus topics the meeting itself
    /// raised ("dynamic"). Empty until something is on the agenda or discovered.
    struct AgendaItem: Identifiable { let id: Int; let text: String; var covered: Bool; var dynamic: Bool }
    @Published private(set) var coverage: [AgendaItem] = []
    @Published var collapsed = false
    /// Whether the floating panel is on screen (toggled via the menu / close button).
    @Published private(set) var visible = false

    // Ask-about-this-meeting (grounded in the live transcript).
    @Published var question = ""
    @Published private(set) var answer = ""
    @Published private(set) var answering = false

    private var panel: NSPanel?
    private var loop: Task<Void, Never>?
    private let polisher = TextPolisher()

    private var transcriptProvider: (() -> String?)?
    private var template: SummaryTemplate = .builtIn(.general)
    private var agenda: [String] = []
    // The meeting's project glossary — kept consistent with the transcription
    // layer so briefs, agenda topics, and answers spell names the same way.
    private var glossary: [String] = []
    // Accumulated agenda state across ticks (kept stable so the list doesn't churn).
    private var dynamicItems: [String] = []   // discovered topic texts, in discovery order
    private var dismissedTopics: Set<String> = []   // lowercased texts the user waved off
    // Manual tick overrides by item id — authoritative over the model, so a
    // hand-checked item stays as the user set it across refreshes.
    private var manualOverrides: [Int: Bool] = [:]
    private var lastBriefedLength = 0

    /// The full accumulated agenda (user + discovered, with covered state) for
    /// writing into the notes. Survives `stop()` so the finalizer can read it.
    var coverageSnapshot: [(text: String, covered: Bool, dynamic: Bool)] {
        coverage.map { ($0.text, $0.covered, $0.dynamic) }
    }

    /// Toggle an agenda item's done state by hand (tap in the panel). The manual
    /// value wins over the model so it doesn't get flipped back on the next tick.
    func toggleCoverage(_ id: Int) {
        guard let idx = coverage.firstIndex(where: { $0.id == id }) else { return }
        let newValue = !coverage[idx].covered
        manualOverrides[id] = newValue
        coverage[idx].covered = newValue
    }

    /// Dismiss a discovered (dynamic) topic as false/irrelevant. It disappears
    /// from the panel, won't be re-suggested, and won't show in the end prompt
    /// or notes. Only dynamic items can be dismissed (user agenda items can't).
    func dismissTopic(_ id: Int) {
        guard let item = coverage.first(where: { $0.id == id }), item.dynamic else { return }
        dismissedTopics.insert(item.text.lowercased())
        manualOverrides[id] = nil
        coverage.removeAll { $0.id == id }
    }

    // Cadence knobs: check often, but only spend a call when the transcript has
    // grown enough since the last brief.
    private let tickSeconds: UInt64 = 25
    private let minGrowthChars = 350

    /// Begin briefing for a meeting. `transcriptProvider` returns the current
    /// notes text (nil if unavailable). No-op if the toggle is off, there's no
    /// API key, or Local-only mode is on.
    func start(transcriptProvider: @escaping () -> String?, template: SummaryTemplate, agenda: [String] = [], glossary: [String] = []) {
        let settings = AppSettings.shared
        guard settings.liveAssistantEnabled, !settings.localOnlyMode,
              KeychainService.groqAPIKey() != nil else { return }

        self.transcriptProvider = transcriptProvider
        self.template = template
        self.agenda = agenda
        self.glossary = glossary
        self.dynamicItems = []
        self.dismissedTopics = []
        self.manualOverrides = [:]
        self.coverage = agenda.enumerated().map { AgendaItem(id: $0.offset, text: $0.element, covered: false, dynamic: false) }
        self.brief = TextPolisher.LiveBrief(tldr: [], actions: [])
        self.lastUpdate = nil
        self.lastBriefedLength = 0
        self.collapsed = false
        self.question = ""
        self.answer = ""

        showPanel()
        loop?.cancel()
        loop = Task { [weak self] in await self?.run() }
    }

    /// Stop briefing and hide the panel.
    func stop() {
        loop?.cancel()
        loop = nil
        transcriptProvider = nil
        // Note: agenda/coverage state is deliberately NOT cleared here — the
        // finalizer reads `coverageSnapshot` to write the notes' Agenda section.
        // start() resets all of it for the next meeting.
        panel?.orderOut(nil)
        visible = false
        updating = false
    }

    /// True while a meeting is actively briefing (loop running).
    var isActive: Bool { loop != nil }

    /// Hide the panel without stopping the briefing — reopen from the menu.
    func hide() {
        panel?.orderOut(nil)
        visible = false
    }

    /// Re-show the panel if a meeting is running.
    func show() {
        guard isActive else { return }
        showPanel()
    }

    /// Clear the current question and its answer.
    func clearAnswer() {
        question = ""
        answer = ""
    }

    // MARK: - Loop

    private func run() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: tickSeconds * 1_000_000_000)
            if Task.isCancelled { return }
            await briefIfGrown()
        }
    }

    private func briefIfGrown() async {
        guard let transcript = transcriptProvider?(), !transcript.isEmpty else { return }
        // Only spend a call when there's meaningfully more to summarize.
        guard transcript.count - lastBriefedLength >= minGrowthChars else { return }

        updating = true
        defer { updating = false }
        do {
            let result = try await polisher.liveBrief(transcript: transcript, template: template, glossary: glossary)
            lastBriefedLength = transcript.count
            if !result.isEmpty {
                brief = result
                lastUpdate = Date()
            }
        } catch {
            Log.meeting.error("❌ Live brief failed: \(error.localizedDescription)")
            // Keep the last good brief on screen; try again next tick.
        }

        // Refresh agenda status alongside the brief. Stateful: we pass the
        // dynamic topics discovered so far so the model keeps them stable and
        // only appends genuinely new ones — the list accumulates rather than
        // churning on each batch's "hot words".
        let status = await polisher.agendaStatus(userAgenda: agenda, knownDynamic: dynamicItems, transcript: transcript, glossary: glossary)

        // The model only SURFACES topics — it never decides they're "resolved".
        // (On the same transcript that surfaced a topic it can't reliably tell
        // "discussed" from "decided", so it would false-tick almost immediately.)
        // New topics are appended once and stay put; nothing auto-resolves.
        for t in status.newTopics
        where !dynamicItems.contains(where: { $0.lowercased() == t.lowercased() })
              && !dismissedTopics.contains(t.lowercased()) {
            dynamicItems.append(t)
        }

        // Both user agenda items and discovered topics complete BY HAND (tap) —
        // no AI auto-marking, so nothing lights up green on refresh.
        let userItems = agenda.enumerated().map { i, text in
            AgendaItem(id: i, text: text, covered: manualOverrides[i] ?? false, dynamic: false)
        }
        // Enumerate over the full list (ids stay stable) but skip dismissed ones.
        let dynEntries = dynamicItems.enumerated().compactMap { i, text -> AgendaItem? in
            guard !dismissedTopics.contains(text.lowercased()) else { return nil }
            let id = agenda.count + i
            return AgendaItem(id: id, text: text, covered: manualOverrides[id] ?? false, dynamic: true)
        }
        coverage = userItems + dynEntries
    }

    /// Answer a question grounded in the meeting transcript so far.
    func ask() {
        let q = question.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, !answering else { return }
        guard let transcript = transcriptProvider?(),
              transcript.trimmingCharacters(in: .whitespacesAndNewlines).count > 20 else {
            answer = "No transcript captured yet — ask again once the meeting has some dialogue."
            return
        }
        answering = true
        answer = ""
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.polisher.answer(question: q, transcript: transcript, glossary: self.glossary)
                self.answer = result
            } catch {
                self.answer = "Couldn't answer: \(error.localizedDescription)"
            }
            self.answering = false
        }
    }

    // MARK: - Panel

    private func showPanel() {
        if panel == nil {
            let hosting = NSHostingView(rootView: LiveAssistantView(assistant: self))
            let p = KeyablePanel(
                contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                styleMask: [.nonactivatingPanel, .fullSizeContentView],
                backing: .buffered, defer: false)
            p.isFloatingPanel = true
            p.level = .floating
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.isMovableByWindowBackground = true
            p.contentView = hosting
            p.isReleasedWhenClosed = false
            panel = p
        }
        positionTopRight()
        panel?.orderFront(nil)
        visible = true
    }

    private func positionTopRight() {
        guard let panel, let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: vf.maxX - size.width - 20,
                                     y: vf.maxY - size.height - 20))
    }

    /// Grow/shrink the panel to fit its SwiftUI content (reported by the view),
    /// keeping it anchored at the top-right so it expands downward.
    func resize(to size: CGSize) {
        guard let panel, size.width > 1, size.height > 1 else { return }
        panel.setContentSize(size)
        positionTopRight()
    }
}

/// A borderless panel that can still take keyboard focus, so the Ask field
/// is typable without activating the whole (menu-bar) app.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - Panel View

/// Carries the SwiftUI content's laid-out size up to the panel controller.
private struct PanelSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

private struct LiveAssistantView: View {
    @ObservedObject var assistant: LiveMeetingAssistant

    var body: some View {
        VStack(alignment: .leading, spacing: assistant.collapsed ? 0 : 8) {
            header

            if !assistant.collapsed {
                if assistant.brief.isEmpty {
                    Text(assistant.updating ? "Summarizing…" : "Listening — a brief appears as the meeting develops.")
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    if !assistant.brief.tldr.isEmpty {
                        section("TL;DR", assistant.brief.tldr, systemImage: "text.line.first.and.arrowtriangle.forward")
                    }
                    if !assistant.brief.actions.isEmpty {
                        section("Open actions", assistant.brief.actions, systemImage: "checklist")
                    }
                }
                if !assistant.coverage.isEmpty {
                    agendaChecklist
                }
                if let t = assistant.lastUpdate {
                    Text("Updated \(t.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2).foregroundColor(.secondary)
                }

                Divider()

                // Ask about the meeting so far, grounded in the live transcript.
                HStack(spacing: 6) {
                    Image(systemName: "questionmark.bubble").foregroundColor(.secondary)
                    TextField("Ask about this meeting…", text: $assistant.question)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                        .onSubmit { assistant.ask() }
                    if assistant.answering {
                        ProgressView().controlSize(.small)
                    } else {
                        Button { assistant.ask() } label: { Image(systemName: "arrow.up.circle.fill") }
                            .buttonStyle(.plain)
                            .disabled(assistant.question.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                if assistant.answering {
                    Label("Thinking…", systemImage: "ellipsis.bubble")
                        .font(.caption).foregroundColor(.secondary)
                }
                if !assistant.answer.isEmpty {
                    HStack {
                        Label("Answer", systemImage: "sparkle")
                            .font(.caption2.weight(.semibold)).foregroundColor(.secondary)
                        Spacer()
                        Button("Clear") { assistant.clearAnswer() }
                            .buttonStyle(.plain)
                            .font(.caption2).foregroundColor(.secondary)
                            .help("Clear the question and answer")
                    }
                    // Rendered directly (no ScrollView): a ScrollView has no
                    // intrinsic height, so inside this self-sizing panel it
                    // collapses to ~0 and the answer becomes invisible. Letting
                    // the text size itself grows the panel to fit.
                    Text(assistant.answer)
                        .font(.caption)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(assistant.collapsed ? 8 : 12)
        .frame(width: assistant.collapsed ? 190 : 300, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
        )
        // Report the laid-out size so the panel window can grow/shrink to fit —
        // otherwise the AppKit panel keeps its initial size and clips content.
        .background(GeometryReader { geo in
            Color.clear.preference(key: PanelSizeKey.self, value: geo.size)
        })
        .onPreferenceChange(PanelSizeKey.self) { assistant.resize(to: $0) }
    }

    // Header doubles as the collapse control: click anywhere on it (except the
    // buttons) to toggle. When collapsed the whole panel shrinks to this row.
    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles").foregroundStyle(.tint)
            Text("Live Brief").font(.subheadline.weight(.semibold))
            if assistant.updating { ProgressView().controlSize(.small) }
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { assistant.collapsed.toggle() }
            } label: {
                Image(systemName: assistant.collapsed ? "chevron.down" : "chevron.up")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .help(assistant.collapsed ? "Expand" : "Collapse")
            Button { assistant.hide() } label: {
                Image(systemName: "xmark").font(.caption)
            }
            .buttonStyle(.plain)
            .help("Hide — reopen from the menu")
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) { assistant.collapsed.toggle() }
        }
    }

    // Agenda coverage — a live checklist so you can see what's still open.
    private var agendaChecklist: some View {
        let done = assistant.coverage.filter(\.covered).count
        return VStack(alignment: .leading, spacing: 3) {
            Label("Agenda (\(done)/\(assistant.coverage.count))", systemImage: "list.bullet.clipboard")
                .font(.caption2.weight(.semibold)).foregroundColor(.secondary)
            ForEach(assistant.coverage) { item in
                HStack(alignment: .top, spacing: 5) {
                    Button { assistant.toggleCoverage(item.id) } label: {
                        Image(systemName: item.covered ? "checkmark.circle.fill" : "circle")
                            .font(.caption2)
                            .foregroundColor(item.covered ? .green : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Tap to mark done / not done")
                    Text(item.text)
                        .font(.caption)
                        .foregroundColor(item.covered ? .secondary : .primary)
                        .strikethrough(item.covered, color: .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if item.dynamic {
                        Image(systemName: "sparkle")
                            .font(.system(size: 7))
                            .foregroundStyle(.tint)
                            .help("Surfaced from the discussion")
                        Spacer(minLength: 2)
                        // Dismiss a false/irrelevant discovered topic.
                        Button { assistant.dismissTopic(item.id) } label: {
                            Image(systemName: "xmark.circle")
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Dismiss — not relevant")
                    }
                }
            }
        }
    }

    private func section(_ title: String, _ items: [String], systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: systemImage)
                .font(.caption2.weight(.semibold)).foregroundColor(.secondary)
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 5) {
                    Text("•").foregroundColor(.secondary)
                    Text(item).font(.caption).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
