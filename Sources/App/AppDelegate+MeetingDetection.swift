import AppKit
import Foundation
import SwiftUI

// MARK: - Meeting Detection & Start Dialog

/// Auto-detection of conferencing calls and the shared start-meeting dialog:
/// the template picker, catalog link, agenda, and per-meeting live-brief switch,
/// plus the session glossary and prep card built from the chosen link. Split out
/// of `AppDelegate`; all state still lives on the delegate.
extension AppDelegate {

    /// A conferencing app started using the mic — offer to transcribe.
    func offerToStartMeeting(for appName: String) {
        guard !appState.isMeetingMode else { return }

        let browser = appName.hasPrefix("browser call")
        confirmMeetingStart(
            title: browser ? "Browser call detected" : "\(appName) call detected",
            message: browser
                ? "\(appName.replacingOccurrences(of: "browser call ", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "()"))) is using your microphone — likely Google Meet or another web call. Start Meeting Mode to transcribe it?"
                : "Looks like a meeting is starting. Start Meeting Mode to transcribe it?",
            confirmTitle: "Start Meeting Mode",
            declineTitle: "Not Now",
            onDecline: { [weak self] in self?.meetingDetector.snooze() })
    }

    /// The single start-meeting dialog: template picker + confirm/decline.
    /// Both the manual (⌃⌥M / menu) and auto-detect paths run through here so
    /// they can't drift apart.
    func confirmMeetingStart(title: String, message: String,
                             confirmTitle: String, declineTitle: String,
                             onDecline: (() -> Void)? = nil) {
        guard !meetingStartPromptActive, !appState.isMeetingMode else { return }
        meetingStartPromptActive = true

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: declineTitle)
        alert.alertStyle = .informational

        // Inline controls: a catalog link (project/org to file the note
        // under), the template (shapes the summary), an optional agenda, and the
        // per-meeting live-brief switch.
        let accessory = Self.makeStartAccessory(selectedID: settings.selectedTemplateID,
                                                catalogOptions: Self.catalogLinkOptions())
        alert.accessoryView = accessory

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            applyTemplateSelection(from: accessory.picker)
            meetingAgenda = Self.parseAgenda(accessory.agendaField.stringValue)
            meetingLiveBrief = accessory.liveBrief.isEnabled ? (accessory.liveBrief.state == .on) : false
            meetingCatalogTarget = resolveCatalogTarget(accessory.catalog.selectedItem?.representedObject as? String)
            // Prep card: surface recent context for the chosen org/opp before
            // recording starts — unless switched off for this meeting.
            if let target = meetingCatalogTarget, accessory.prepCard.state == .on {
                showMeetingPrepCard(for: target)
            }
            // Hold the prompt flag through the async start so a queued ⌃⌥M
            // can't open a spurious second dialog before isMeetingMode flips.
            Task { @MainActor in
                await startMeetingMode()
                meetingStartPromptActive = false
            }
        } else {
            meetingStartPromptActive = false
            onDecline?()
        }
    }

    /// Build the start-dialog catalog picker options: projects, orgs, and two
    /// quick-add entries. Runs on the main actor (CatalogStore is isolated).
    private static func catalogLinkOptions() -> [(title: String, repr: String)] {
        MainActor.assumeIsolated {
            let store = CatalogStore.shared
            var opts: [(String, String)] = [("No link", "")]
            // One consistent org→project tree, indented by depth (same shape the
            // SwiftUI OrgProjectTreePicker renders elsewhere).
            let rows = store.orgProjectRows()
            if !rows.isEmpty { opts.append(("__sep__", "__sep__")) }
            for r in rows {
                let indent = String(repeating: "    ", count: r.depth)
                let icon = r.kind == "org" ? "🏢" : "◆"
                opts.append(("\(indent)\(icon) \(r.name)", "\(r.kind):\(r.id)"))
            }
            opts.append(("__sep__", "__sep__"))
            opts.append(("➕ New Project…", "new:project"))
            opts.append(("➕ New Organisation…", "new:org"))
            return opts.map { (title: $0.0, repr: $0.1) }
        }
    }

    /// Turn the picker's selection into a catalog target, handling the two
    /// quick-add entries by prompting for a name and creating the entity.
    private func resolveCatalogTarget(_ repr: String?) -> (kind: String, id: String)? {
        guard let repr, !repr.isEmpty else { return nil }
        // A new project gets the full Quick Add (org → project → …).
        if repr == "new:project" {
            return runQuickAddForProject().map { ("project", $0) }
        }
        if repr == "new:org" {
            guard let name = promptNewCatalogName("New Organisation") else { return nil }
            return MainActor.assumeIsolated { ("org", CatalogStore.shared.addOrg(name: name).id) }
        }
        let parts = repr.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        return (parts[0], parts[1])
    }

    /// Proper-noun glossary for the meeting in progress — the linked entity
    /// (project / org), the people on its recent notes, and the
    /// voice identities taught so far — capped and formatted for the Whisper
    /// prompt. CatalogStore is main-actor isolated, so this is too.
    @MainActor
    func buildSessionGlossary(for target: (kind: String, id: String)?) -> String {
        let store = CatalogStore.shared
        var terms: [String] = []
        var scope: [CatalogNote] = []

        if let target {
            if target.kind == "project", let proj = store.project(target.id) {
                terms.append(proj.name)
                if let org = store.org(forProject: proj.id) { terms.append(org.name) }
                scope = store.notes(forProject: proj.id)
            } else if target.kind == "org", let org = store.org(target.id) {
                terms.append(org.name)
                scope = store.notes(forOrg: org.id, includingDescendants: true)
            }
        }

        // People who appear on the linked entity's notes.
        let personIDs = Set(scope.flatMap { $0.personIDs })
        terms.append(contentsOf: store.doc.people.filter { personIDs.contains($0.id) }.map(\.name))

        // Dedupe (case-insensitive), drop empties, cap length for Whisper's
        // short prompt window.
        var seen = Set<String>(), unique: [String] = []
        for t in terms {
            let name = t.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, seen.insert(name.lowercased()).inserted else { continue }
            unique.append(name)
        }
        guard !unique.isEmpty else { return "" }
        return String(("Names: " + unique.joined(separator: ", ")).prefix(400))
    }

    /// Meeting prep card: a quick, non-editable recap of recent context for the
    /// org/project chosen in the Start dialog, shown just before recording.
    /// Reuses the catalog's relationship timeline (recent notes). Skipped when
    /// there's no prior history to show.
    private func showMeetingPrepCard(for target: (kind: String, id: String)) {
        let prep: (name: String, notes: [CatalogNote])? = MainActor.assumeIsolated {
            let store = CatalogStore.shared
            let name: String
            let notes: [CatalogNote]
            if target.kind == "project", let o = store.project(target.id) {
                name = o.name; notes = store.notes(forProject: o.id)
            } else if target.kind == "org", let o = store.org(target.id) {
                name = store.orgPath(of: o.id); notes = store.notes(forOrg: o.id, includingDescendants: true)
            } else { return nil }
            let recent = Array(notes.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }.prefix(3))
            return recent.isEmpty ? nil : (name, recent)
        }
        guard let prep else { return }   // nothing to prep from — don't interrupt
        // Non-modal so you can open and read a note while the meeting records.
        MeetingPrepWindowController.present(entityName: prep.name, notes: prep.notes)
    }

    /// Present the Quick Add sheet modally and return the created project's id
    /// (nil if cancelled or no project was named).
    private func runQuickAddForProject() -> String? {
        MainActor.assumeIsolated {
            var result: String?
            let controller = NSHostingController(rootView: QuickAddSheet(store: CatalogStore.shared) { projID in
                result = projID
                NSApp.stopModal()
            })
            let window = NSWindow(contentViewController: controller)
            window.title = "Quick Add"
            window.styleMask = [.titled]
            NSApp.runModal(for: window)
            window.orderOut(nil)
            return result
        }
    }

    /// Simple name prompt for the quick-add catalog entries.
    private func promptNewCatalogName(_ title: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Name"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// Accessory view for the start dialog: a catalog-link popup, a template
    /// popup (shapes the summary), an optional agenda field, and a live-brief switch.
    private final class StartAccessory: NSView {
        let catalog = NSPopUpButton(frame: .zero, pullsDown: false)
        let search = NSSearchField(frame: .zero)
        let picker = NSPopUpButton(frame: .zero, pullsDown: false)
        let agendaField = NSTextField(frame: .zero)
        let liveBrief = NSSwitch(frame: .zero)
        let prepCard = NSSwitch(frame: .zero)
        let prepLabel = NSTextField(labelWithString: "Show prep card")

        /// Full link options (No link, org/opp rows, quick-add). The popup is
        /// rebuilt from this, filtered by the search field, so the list stays
        /// usable as the Catalog grows.
        var allOptions: [(title: String, repr: String)] = []

        /// Repopulate the link popup, keeping "No link" and the quick-add rows
        /// while narrowing the org/project rows to those matching `filter`.
        func rebuildCatalogMenu(filter: String) {
            let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
            let prevRepr = catalog.selectedItem?.representedObject as? String

            // Keep an entity row only when it matches; leave fixed rows alone.
            var shown = allOptions.filter { opt in
                let isEntity = opt.repr.hasPrefix("project:") || opt.repr.hasPrefix("org:")
                return !isEntity || q.isEmpty || opt.title.lowercased().contains(q)
            }
            // Collapse separators left dangling by filtering.
            var cleaned: [(title: String, repr: String)] = []
            for opt in shown where !(opt.repr == "__sep__" && (cleaned.isEmpty || cleaned.last?.repr == "__sep__")) {
                cleaned.append(opt)
            }
            if cleaned.last?.repr == "__sep__" { cleaned.removeLast() }
            shown = cleaned

            catalog.removeAllItems()
            catalog.menu?.autoenablesItems = false
            for opt in shown {
                if opt.repr == "__sep__" { catalog.menu?.addItem(.separator()); continue }
                let item = NSMenuItem(title: opt.title, action: nil, keyEquivalent: "")
                item.representedObject = opt.repr
                catalog.menu?.addItem(item)
            }
            if let prevRepr, let item = catalog.menu?.items.first(where: { ($0.representedObject as? String) == prevRepr }) {
                catalog.select(item)
            }
            catalogChanged()
        }

        @objc func searchChanged() { rebuildCatalogMenu(filter: search.stringValue) }

        /// The prep card only makes sense with a catalog link — enable the
        /// switch (and un-dim its label) only when an org/project is chosen.
        @objc func catalogChanged() {
            let repr = catalog.selectedItem?.representedObject as? String ?? ""
            let linked = !repr.isEmpty && repr != "__sep__"
            prepCard.isEnabled = linked
            prepLabel.textColor = linked ? .labelColor : .tertiaryLabelColor
        }
    }

    /// Build the start-dialog accessory. An accessory view without explicit
    /// frames renders but doesn't receive clicks in NSAlert, so everything is
    /// laid out with explicit frames.
    private static func makeStartAccessory(selectedID: String, catalogOptions: [(title: String, repr: String)]) -> StartAccessory {
        let width: CGFloat = 300
        // Consistent vertical rhythm: a caption sits `capGap` above its control,
        // and groups are separated by `groupGap`. Everything is laid out top-down
        // with a cursor so the spacing stays even and easy to retune.
        let capH: CGFloat = 15, popH: CGFloat = 26, fieldH: CGFloat = 44, rowH: CGFloat = 22
        let capGap: CGFloat = 3, groupGap: CGFloat = 14, rowGap: CGFloat = 6
        let height = capH + capGap + popH + rowGap + popH + groupGap   // link: caption + search + popup
                   + capH + capGap + popH + groupGap
                   + capH + capGap + fieldH + groupGap
                   + rowH + rowGap + rowH
        let container = StartAccessory(frame: NSRect(x: 0, y: 0, width: width, height: height))

        // Distance consumed from the top edge; `place` reserves the next element
        // and returns its bottom-left-origin y.
        var top: CGFloat = 0
        func place(_ h: CGFloat) -> CGFloat {
            let y = height - top - h
            top += h
            return y
        }
        func caption(_ text: String) {
            let field = NSTextField(labelWithString: text)
            field.frame = NSRect(x: 0, y: place(capH), width: width, height: capH)
            field.font = .boldSystemFont(ofSize: 11)
            field.textColor = .secondaryLabelColor
            container.addSubview(field)
            top += capGap
        }

        // Catalog link (top) — file this meeting's note under a project or
        // org. A search field narrows the list as the Catalog grows.
        caption("Link to (optional)")
        let search = container.search
        search.frame = NSRect(x: 0, y: place(popH), width: width, height: popH)
        search.placeholderString = "Search organisations & projects…"
        search.sendsWholeSearchString = false
        search.target = container
        search.action = #selector(StartAccessory.searchChanged)
        container.addSubview(search)
        top += rowGap

        let catalog = container.catalog
        catalog.frame = NSRect(x: 0, y: place(popH), width: width, height: popH)
        catalog.target = container
        catalog.action = #selector(StartAccessory.catalogChanged)
        container.allOptions = catalogOptions
        container.rebuildCatalogMenu(filter: "")
        container.addSubview(catalog)
        top += groupGap

        // Meeting type (middle) — shapes the summary.
        caption("Meeting type")
        let picker = container.picker
        picker.frame = NSRect(x: 0, y: place(popH), width: width, height: popH)
        // Grouped: a disabled section header per category, then its templates.
        // autoenablesItems must be off or the menu re-enables the headers,
        // making them look pickable (and one can show as the selection).
        picker.menu?.autoenablesItems = false
        for group in AppSettings.shared.groupedTemplates {
            let header = NSMenuItem(title: group.title, action: nil, keyEquivalent: "")
            header.isEnabled = false
            picker.menu?.addItem(header)
            for template in group.templates {
                let item = NSMenuItem(title: template.displayName, action: nil, keyEquivalent: "")
                item.indentationLevel = 1
                item.representedObject = template.id
                picker.menu?.addItem(item)
            }
        }
        // Select the stored template, else fall back to the first real item so
        // the popup never rests on a header.
        let match = picker.menu?.items.first { ($0.representedObject as? String) == selectedID }
            ?? picker.menu?.items.first { $0.representedObject != nil }
        if let match { picker.select(match) }
        container.addSubview(picker)
        top += groupGap

        // Agenda (optional) — drives the end-of-meeting coverage check.
        caption("Agenda")
        let field = container.agendaField
        field.frame = NSRect(x: 0, y: place(fieldH), width: width, height: fieldH)
        field.placeholderString = "Optional — separate items with commas"
        field.usesSingleLineMode = false
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.lineBreakMode = .byWordWrapping
        field.font = .systemFont(ofSize: 12)
        container.addSubview(field)
        top += groupGap

        // Live brief (bottom) — per-meeting choice, defaulting to the global
        // setting, as a Settings-style row: label left, switch right. Hard-
        // disabled when it couldn't run anyway (local-only / no key) so the
        // dialog never offers something that silently does nothing.
        let settings = AppSettings.shared
        let canRun = !settings.localOnlyMode && KeychainService.groqAPIKey() != nil
        let rowY = place(rowH)
        let live = container.liveBrief
        live.controlSize = .mini
        live.sizeToFit()
        live.frame = NSRect(x: width - live.frame.width,
                            y: rowY + (rowH - live.frame.height) / 2,
                            width: live.frame.width, height: live.frame.height)
        live.state = (canRun && settings.liveAssistantEnabled) ? .on : .off
        live.isEnabled = canRun

        let liveLabel = NSTextField(labelWithString: "Show live brief")
        liveLabel.frame = NSRect(x: 0, y: rowY + (rowH - 16) / 2,
                                 width: width - live.frame.width - 8, height: 16)
        liveLabel.font = .systemFont(ofSize: 12)
        liveLabel.textColor = canRun ? .labelColor : .tertiaryLabelColor
        let tip = canRun
            ? "Floating in-meeting brief (TL;DR, actions, agenda coverage). Defaults to your global setting; applies to this meeting only."
            : settings.localOnlyMode
                ? "Unavailable in local-only mode — the live brief needs the cloud."
                : "Add a Groq API key to use the live brief."
        live.toolTip = tip
        liveLabel.toolTip = tip
        container.addSubview(liveLabel)
        container.addSubview(live)

        // Prep card (below live brief) — show recent notes for the linked
        // org/opp when this meeting starts. On by default; only ever appears
        // when a link is chosen and it has prior notes.
        top += rowGap
        let prepRowY = place(rowH)
        let prep = container.prepCard
        prep.controlSize = .mini
        prep.sizeToFit()
        prep.frame = NSRect(x: width - prep.frame.width,
                            y: prepRowY + (rowH - prep.frame.height) / 2,
                            width: prep.frame.width, height: prep.frame.height)
        prep.state = AppSettings.shared.meetingPrepCard ? .on : .off
        let prepLabel = container.prepLabel
        prepLabel.frame = NSRect(x: 0, y: prepRowY + (rowH - 16) / 2,
                                 width: width - prep.frame.width - 8, height: 16)
        prepLabel.font = .systemFont(ofSize: 12)
        let prepTip = "When linked to an org/project, pops a panel of its recent notes as the meeting starts. Applies to this meeting only."
        prep.toolTip = prepTip
        prepLabel.toolTip = prepTip
        container.addSubview(prepLabel)
        container.addSubview(prep)

        // Set the prep switch's initial enabled state from the default link.
        container.catalogChanged()

        return container
    }

    /// Split a comma / newline / semicolon-separated agenda string into items.
    private static func parseAgenda(_ raw: String) -> [String] {
        raw.components(separatedBy: CharacterSet(charactersIn: ",\n;"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func applyTemplateSelection(from picker: NSPopUpButton) {
        guard let id = picker.selectedItem?.representedObject as? String else { return }
        settings.selectedTemplateID = id
    }

    /// The tracked call released the mic while Meeting Mode is still running —
    /// offer to stop instead of transcribing an empty room. Routes through the
    /// same coverage check as a manual end so the open-items list is folded into
    /// this one prompt rather than shown as a second dialog afterwards.
    func offerToStopMeeting() {
        guard appState.isMeetingMode else { return }
        Task { @MainActor in await confirmEndAndStopMeeting(callEnded: true) }
    }
}
