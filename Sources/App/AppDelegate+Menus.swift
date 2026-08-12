import AppKit
import Foundation

// MARK: - Menus & User-Facing Status

/// Menu-bar construction and the user-facing status surface (stats line, Live
/// Brief toggles, recent-notes submenu, speaker identification, error banner).
/// Split out of `AppDelegate` to keep the delegate focused on the recording and
/// meeting lifecycle; all state still lives on `AppDelegate`.
extension AppDelegate {

    // MARK: - Menu Updates

    /// Rebuilds the Notes submenu (and refreshes the Main menu) on open.
    @MainActor
    func menuNeedsUpdate(_ menu: NSMenu) {
        switch menu.title {
        case "Main":
            let stats = UsageStats.shared
            let weekMeetings = stats.meetingsThisWeek(in: settings.notesFolder)
            var statsLine = "\(weekMeetings) meeting\(weekMeetings == 1 ? "" : "s") this week · \(stats.dictationCount) dictations"
            // Surface the running cost estimate when there's been any spend.
            if !settings.localOnlyMode, stats.estimatedCostUSD >= 0.01 {
                statsLine += " · ~\(UsageStats.currency(stats.estimatedCostUSD))"
                // Flag when this month's spend has crossed the soft budget.
                if stats.isOverBudget {
                    statsLine += " ⚠️ over budget"
                }
            }
            statsMenuItem?.title = statsLine
            // Pause only makes sense mid-meeting — hide it otherwise.
            pauseMenuItem?.isHidden = !appState.isMeetingMode
            // Live Brief show/hide — only while its panel is running.
            let live = LiveMeetingAssistant.shared
            // Available whenever a meeting is running and the brief could run —
            // so it can be started mid-meeting even if it began switched off.
            let canRunLive = !settings.localOnlyMode && KeychainService.groqAPIKey() != nil
            liveBriefMenuItem?.isHidden = !(appState.isMeetingMode && canRunLive)
            liveBriefMenuItem?.title = live.isActive
                ? (live.visible ? "Hide Live Brief" : "Show Live Brief")
                : (live.ended ? "Resume Live Brief" : "Start Live Brief")
            // "Turn Off" only makes sense while it's actively running.
            liveBriefEndMenuItem?.isHidden = !live.isActive
            // Error banner — visible only when there's a recent failure.
            if let message = appState.lastError {
                errorMenuItem?.isHidden = false
                errorMenuItem?.title = "\(message)  (click to dismiss)"
            } else {
                errorMenuItem?.isHidden = true
            }

        case "Recent Notes":
            menu.removeAllItems()

            // Current (or latest) meeting notes — same action as ⌃⌥N —
            // and today's quick notes, the two "get me to my notes" verbs.
            let openItem = NSMenuItem(title: appState.isMeetingMode ? "Open Current Meeting Notes" : "Open Latest Meeting Notes",
                                      action: #selector(openNotes), keyEquivalent: shortcutLetter(.openNotes))
            openItem.keyEquivalentModifierMask = [.control, .option]
            openItem.target = self
            menu.addItem(openItem)
            // Title reflects what actually opens: today's file if it exists,
            // otherwise the most recent quick-notes file, otherwise the folder.
            let hasTodayQuickNotes = FileManager.default.fileExists(
                atPath: MeetingNotesWriter.todaysQuickNotesURL().path)
            let quickNotesTitle = hasTodayQuickNotes
                ? "Open Today's Quick Notes"
                : (MeetingNotesWriter.latestQuickNotesFile() != nil ? "Open Latest Quick Notes" : "Open Quick Notes Folder")
            let quickNotesItem = NSMenuItem(title: quickNotesTitle, action: #selector(openTodaysQuickNotes), keyEquivalent: "")
            quickNotesItem.target = self
            menu.addItem(quickNotesItem)
            menu.addItem(NSMenuItem.separator())

            // Only the 5 most recent here — the Catalog (below) is the full,
            // searchable browser.
            let files = MeetingNotesWriter.allMeetingFiles(under: settings.notesFolder).prefix(5)

            if files.isEmpty {
                let empty = NSMenuItem(title: "No meetings yet", action: nil, keyEquivalent: "")
                empty.isEnabled = false
                menu.addItem(empty)
            }
            // Group by day so the menu mirrors the notes-folder hierarchy.
            var currentDay = ""
            for file in files {
                let stamp = file.deletingPathExtension().lastPathComponent
                    .replacingOccurrences(of: "Meeting_", with: "")   // yyyy-MM-dd_HH-mm-ss
                let day = String(stamp.prefix(10))
                let time = stamp.count > 11
                    ? String(stamp.dropFirst(11)).replacingOccurrences(of: "-", with: ":")
                    : stamp
                if day != currentDay {
                    currentDay = day
                    let header = NSMenuItem(title: DateDisplay.day(day), action: nil, keyEquivalent: "")
                    header.isEnabled = false
                    menu.addItem(header)
                }
                let item = NSMenuItem(title: time, action: #selector(openMeetingFile(_:)), keyEquivalent: "")
                item.indentationLevel = 1
                item.target = self
                item.representedObject = file
                menu.addItem(item)
            }
            // The Catalog is the single, full, searchable notes browser — this
            // submenu is just quick jumps, so link out to it explicitly.
            if !files.isEmpty {
                let browseItem = NSMenuItem(title: "Browse All Notes in Catalog…", action: #selector(showCatalogNotes), keyEquivalent: "")
                browseItem.indentationLevel = 0
                browseItem.target = self
                menu.addItem(browseItem)
            }
            menu.addItem(NSMenuItem.separator())
            let renameItem = NSMenuItem(title: "Identify Speakers…", action: #selector(showRenameSpeakers), keyEquivalent: "")
            renameItem.target = self
            menu.addItem(renameItem)
            let folderItem = NSMenuItem(title: "Open Notes Folder…", action: #selector(openNotesFolder), keyEquivalent: "")
            folderItem.target = self
            menu.addItem(folderItem)

        default:
            break
        }
    }

    // MARK: - Menu Actions

    @objc func clearDictationHistory() {
        dictationHistory.removeAll()
    }

    /// Open a meeting note in the in-app viewer/editor (which itself offers
    /// "Open in Default App", "Reveal in Finder", and "Draft Follow-up").
    @objc func openMeetingFile(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NotesViewerWindowController.present(fileURL: url)
    }

    /// Rename Them / Them 2 to real names — per meeting. Opens with the live
    /// meeting preselected when one is running; renames touch only the chosen
    /// file, and live-session overrides apply only to the current meeting.
    @objc func showRenameSpeakers() {
        presentRenameSpeakers(preselect: nil)
    }

    /// From the notes viewer: rename speakers with that note preselected.
    @objc func renameSpeakersForFile(_ note: Notification) {
        presentRenameSpeakers(preselect: note.object as? URL)
    }

    private func presentRenameSpeakers(preselect: URL?) {
        renameSpeakersWindowController = RenameSpeakersWindowController(
            liveFile: meetingNotes.currentFilePath,
            preselect: preselect,
            onRename: { [weak self] old, new, personID, file in
                guard let self else { return }
                // Manual identification only: rename the label in this note and
                // link the person to it. No voiceprint is taught — cross-meeting
                // acoustic auto-identification was removed (too unreliable).
                if let personID {
                    Task { @MainActor in CatalogStore.shared.linkPerson(personID, toFile: file) }
                }
                // Keep a live meeting using the new name for later segments.
                if self.meetingNotes.currentFilePath == file {
                    self.meetingNotes.setNameOverride(new, replacing: old)
                }
            })
        renameSpeakersWindowController?.bringToFront()
    }

    /// Opens today's QuickNotes file, or the most recent one, or the folder.
    @objc func openTodaysQuickNotes() {
        if let url = MeetingNotesWriter.latestQuickNotesFile() {
            NSWorkspace.shared.open(url)
        } else {
            let folder = settings.quickNotesFolder
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(folder)
        }
    }

    @objc func openNotesFolder() {
        let folder = settings.notesFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    // MARK: - Error Surface

    /// Surface a non-fatal error: remember it for the menu and post a
    /// notification. Safe to call from any thread.
    func reportError(_ message: String) {
        Log.app.error("❗️ \(message)")
        DiagnosticsLog.shared.record(message)
        Task { @MainActor in
            self.appState.lastError = message
            if self.settings.errorNotifications {
                NotificationManager.shared.notifyError(message)
            }
        }
    }

    /// Clear the current surfaced error (from the menu).
    @objc func dismissLastError() {
        appState.lastError = nil
    }

    func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "GhostWriter"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
            NSWorkspace.shared.open(url)
        }
    }
}
