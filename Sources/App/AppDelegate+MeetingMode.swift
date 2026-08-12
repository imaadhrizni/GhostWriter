import AppKit
import Foundation

// MARK: - Meeting Mode Lifecycle

/// Start / stop of Meeting Mode: the end-of-meeting coverage check, capture-chain
/// startup (system + mic audio, live brief, retention recorder, overlay), the
/// elapsed-time menu-bar timer, and finalization. Split out of `AppDelegate`;
/// all state still lives on the delegate.
extension AppDelegate {

    @objc func toggleMeetingMode() {
        if appState.isMeetingMode {
            Task { @MainActor in await confirmEndAndStopMeeting() }
        } else {
            promptTemplateAndStartMeeting()
        }
    }

    /// "Ask before it ends": when a meeting ends, warn about anything still
    /// open — the user's uncovered agenda items AND any dynamically-discovered
    /// topics raised but left unresolved — and offer to keep recording.
    ///
    /// `callEnded` marks the auto-detect path (a tracked call released the mic):
    /// there we always confirm (detection can misfire), and the open-items list,
    /// if any, is folded into that single "Call ended" prompt. A manual end
    /// (menu / ⌃⌥M) stops straight away when nothing is outstanding.
    @MainActor
    func confirmEndAndStopMeeting(callEnded: Bool = false) async {
        guard !endCoverageChecking else { return }

        let assistant = LiveMeetingAssistant.shared
        var uncovered: [String]
        if assistant.isActive {
            // Reuse the live panel's accumulated coverage (user ticks + the
            // discovered topics and their resolved state) — no extra model call.
            uncovered = assistant.coverageSnapshot.filter { !$0.covered }
                .map { $0.dynamic ? "\($0.text) (raised, unresolved)" : $0.text }
            Log.meeting.info("🔎 End-coverage (live): flagged=\(uncovered.count)")
        } else {
            // No live panel — do a one-shot read, if there's a cloud path and content.
            let settings = AppSettings.shared
            let transcript = meetingNotes.currentFilePath.flatMap { meetingNotes.transcriptText(of: $0) } ?? ""
            let spoken = MeetingRefinery.dialogueLength(of: transcript)
            if !settings.localOnlyMode, KeychainService.groqAPIKey() != nil, spoken > 200 {
                endCoverageChecking = true
                meetingModeMenuItem?.title = "Checking coverage…"
                let status = await textPolisher.agendaStatus(
                    userAgenda: meetingAgenda,
                    transcript: transcript.trimmingCharacters(in: .whitespacesAndNewlines),
                    preferFast: false)
                endCoverageChecking = false
                meetingModeMenuItem?.title = appState.isMeetingMode ? "End Meeting" : "Start Meeting"
                let userUncovered = zip(meetingAgenda, status.userCovered).filter { !$0.1 }.map { $0.0 }
                let openTopics = status.newTopics.map { "\($0) (raised, unresolved)" }
                uncovered = userUncovered + openTopics
                Log.meeting.info("🔎 End-coverage (model): flagged=\(uncovered.count)")
            } else {
                Log.meeting.info("⏭ End-coverage skipped (local=\(settings.localOnlyMode), spoken=\(spoken))")
                uncovered = []
            }
        }

        // The meeting may have been stopped another way while we were checking.
        guard appState.isMeetingMode else { return }

        // Manual end with nothing outstanding: stop, no dialog. (An auto-detected
        // call always confirms — detection can be wrong.)
        if !callEnded && uncovered.isEmpty { stopMeetingMode(); return }

        let bullets = uncovered.map { "•  \($0)" }.joined(separator: "\n")
        let alert = NSAlert()
        alert.alertStyle = .informational
        if callEnded {
            alert.messageText = "Call ended"
            alert.informativeText = uncovered.isEmpty
                ? "The call seems to be over, but Meeting Mode is still recording. Stop and finalize the notes?"
                : "The call seems to be over. These points still look open:\n\n\(bullets)\n\nStop and finalize the notes?"
            alert.addButton(withTitle: "Stop & Save Notes")   // default: the call really is over
            alert.addButton(withTitle: "Keep Recording")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn { stopMeetingMode() }
        } else {
            alert.messageText = "Before you end this meeting"
            alert.informativeText = "These points still look open:\n\n\(bullets)"
            alert.addButton(withTitle: "Keep Recording")      // default: guard against an accidental end
            alert.addButton(withTitle: "End Anyway")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() != .alertFirstButtonReturn { stopMeetingMode() }
        }
    }

    /// Manual start (menu or ⌃⌥M): confirm the meeting template first so the
    /// summary matches the kind of meeting.
    func promptTemplateAndStartMeeting() {
        confirmMeetingStart(
            title: "Start Meeting Mode",
            message: "What kind of meeting is this? The template shapes what the summary extracts.",
            confirmTitle: "Start",
            declineTitle: "Cancel")
    }

    @MainActor
    func startMeetingMode() async {
        // Re-entrancy guard: two confirm dialogs (or a dialog + hotkey) must
        // never double-start the capture chain and leak timers.
        guard !appState.isMeetingMode else { return }
        // Transcription needs the Groq key — fail fast with guidance instead of
        // silently producing an empty notes file.
        guard KeychainService.groqAPIKey() != nil else {
            showAPIKeyWindow()
            return
        }

        // Starting the capture chain surfaces the System Audio Recording TCC
        // prompt on first use; a failure here usually means it was denied.
        do {
            try await systemAudioCapture.start()
        } catch {
            Log.meeting.error("❌ Could not start system audio capture: \(error.localizedDescription)")
            showError("System Audio Recording permission is required for Meeting Mode. Enable GhostWriter in System Settings → Privacy & Security → Screen & System Audio Recording.")
            return
        }

        appState.isMeetingMode = true
        appState.meetingCaption = "Listening to meeting…"
        appState.isSpeakerActive = false
        setTranscriptionPaused(false)
        pauseMenuItem?.title = "Pause Meeting"
        meetingModeMenuItem?.title = "End Meeting"
        meetingStartTime = Date()
        meetingDetector.suppressed = true
        meetingNotes.beginSession()

        // Retain the raw audio (opt-out) so a failed transcription can be
        // regenerated from the recording. Keyed to this meeting's note file.
        if settings.retainMeetingAudio, let noteURL = meetingNotes.currentFilePath {
            // Mirror the note's dated organization under <notes>/Audio/.
            let retainer = AudioRetainer(
                baseName: noteURL.deletingPathExtension().lastPathComponent,
                audioDir: settings.audioDestinationFolder(for: meetingStartTime ?? Date()))
            retainer.start()
            audioRetainer = retainer
        } else {
            audioRetainer = nil
        }

        // Prime Whisper with the proper nouns for this meeting (linked entity
        // and its people) so names transcribe right from the start.
        GroqService.sessionGlossary = buildSessionGlossary(for: meetingCatalogTarget)

        // Reset the speaker profiles for the new session (safe to touch
        // directly — the capture callbacks haven't started yet)
        speakerProfiler.reset()

        // Live in-meeting brief (opt-in; reads the growing notes file).
        LiveMeetingAssistant.shared.start(
            transcriptProvider: { [weak self] in
                guard let url = self?.meetingNotes.currentFilePath else { return nil }
                return self?.meetingNotes.transcriptText(of: url)
            },
            template: settings.selectedTemplate,
            agenda: meetingAgenda,
            enabled: meetingLiveBrief)

        // Menu-bar elapsed timer — doubles as a "still recording" indicator
        startMeetingTimer()

        // Update status bar icon
        statusItem?.button?.image = NSImage(systemSymbolName: "headphones.circle.fill", accessibilityDescription: "Meeting Mode")

        // Overlay behavior per settings: captions / minimal pill / hidden
        if let panel = overlayPanel {
            switch settings.overlayMode {
            case .captions, .minimal:
                // Wider panel so the caption line has room (minimal just leaves it blank)
                panel.setContentSize(NSSize(width: 380, height: 120))
                positionOverlayPanel(panel)
                panel.ignoresMouseEvents = false  // allow dragging the pill
                panel.orderFront(nil)
            case .hidden:
                panel.orderOut(nil)
            }
        }
        Log.meeting.info("📡 Meeting Mode ON")

        setupMeetingAudioCallback()
        setupMicMeetingCallback()
    }

    func startMeetingTimer() {
        meetingTimer?.invalidate()
        meetingTimer = Timer.scheduledTimer(
            timeInterval: 1, target: self, selector: #selector(updateMeetingTimer),
            userInfo: nil, repeats: true)
    }

    @objc func updateMeetingTimer() {
        guard let start = meetingStartTime else { return }
        let elapsed = Int(Date().timeIntervalSince(start))
        statusItem?.button?.title = String(format: " %d:%02d", elapsed / 60, elapsed % 60)
    }

    func stopMeetingMode() {
        meetingTimer?.invalidate()
        meetingTimer = nil
        statusItem?.button?.title = ""
        // Hand the agenda to the finalizer (for the notes' Agenda section)
        // before clearing it for the next meeting.
        let agendaForNotes = meetingAgenda
        meetingAgenda = []
        // Snapshot the catalog target NOW, before the async finalize below.
        // It's a shared field; a meeting started during the ~20s finalize wait
        // would otherwise overwrite it, mislinking this note (or dropping the
        // link entirely). Clearing it here also prevents leaking into the next.
        let catalogTargetForNotes = meetingCatalogTarget
        meetingCatalogTarget = nil

        // Session glossary is per-meeting — clear it so it can't bias the next
        // meeting's transcription (or dictation) with stale names.
        GroqService.sessionGlossary = ""

        micCapture.stop()
        systemAudioCapture.stop()

        // Don't immediately re-prompt "start Meeting Mode?" for the very call
        // the user just chose to stop transcribing.
        meetingDetector.suppressed = false
        meetingDetector.snooze()

        // Flush the tail speech still sitting in the buffers — the last words of
        // a meeting must be transcribed, not discarded. (flush* resets the state.)
        micMeetingQueue.sync { flushMicMeetingSegment() }
        meetingQueue.sync { flushMeetingSegment() }

        echoGateLock.lock()
        speakerLastActiveTime = nil
        echoGateLock.unlock()

        setTranscriptionPaused(false)
        DispatchQueue.main.async { [weak self] in
            self?.pauseMenuItem?.title = "Pause Meeting"
        }

        if let start = meetingStartTime {
            meetingStartTime = nil
            UsageStats.shared.recordMeeting(seconds: Date().timeIntervalSince(start))

            // Finalize asynchronously: wait for in-flight transcriptions (incl.
            // the tail we just flushed) so they land in the file, give queued
            // failures one last retry, then write the footer + summary.
            let retainer = audioRetainer
            audioRetainer = nil
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.waitForPendingTranscriptions(timeout: 20)
                await self.finalRetryPass()
                self.meetingNotes.endSession(startedAt: start)
                // Finish the recording and record its path on the note before the
                // refinement pass writes the rest of the front-matter.
                if let retainer, let audioURL = await retainer.finish(),
                   let noteURL = self.meetingNotes.lastCompletedFilePath {
                    // Path relative to the notes folder (includes the dated subfolders).
                    MeetingNotesWriter.setAudioPath(self.settings.relativePath(of: audioURL), to: noteURL)
                }
                self.finalizeMeetingNotes(startedAt: start, agenda: agendaForNotes,
                                          catalogTarget: catalogTargetForNotes)
            }
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.appState.isMeetingMode = false
            self.appState.meetingCaption = ""
            self.appState.isSpeakerActive = false
            LiveMeetingAssistant.shared.stop()
            self.meetingModeMenuItem?.title = "Start Meeting"
            self.statusItem?.button?.image = NSImage(systemSymbolName: "waveform.circle.fill", accessibilityDescription: "GhostWriter")

            if let panel = self.overlayPanel {
                panel.ignoresMouseEvents = true  // restore pass-through
                panel.setContentSize(NSSize(width: 180, height: 180))  // back to PTT size
                self.positionOverlayPanel(panel)
                if self.appState.recordingState == .idle {
                    panel.orderOut(nil)
                }
            }
            Log.meeting.info("📡 Meeting Mode OFF")
        }
    }

    func setupMeetingAudioCallback() {
        let vad = VoiceActivityDetector()
        systemAudioCapture.onAudioBuffer = { [weak self] buffer in
            guard let self, !self.isTranscriptionPaused else { return }
            self.audioRetainer?.appendSystem(buffer)
            let rms = vad.calculateRMS(from: buffer)
            let dbfs = vad.rmsToDBFS(rms)
            let isVoice = dbfs >= self.settings.systemAudioThreshold
            self.meetingQueue.async { [weak self] in
                self?.processMeetingBuffer(buffer, isVoice: isVoice, rms: rms)
            }
        }
    }
}
